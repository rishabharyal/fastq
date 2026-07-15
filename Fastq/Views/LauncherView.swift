import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var sessions: SessionStore
    @ObservedObject var auth: FastplayAuthStore
    let launcher: AgentLauncher
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    var onOpenAccountSettings: (() -> Void)? = nil
    var onOpenBoards: (() -> Void)? = nil
    var onOpenOnboarding: (() -> Void)? = nil
    var onOpenTerminal: (() -> Void)? = nil

    @State private var prompt: String = ""
    @State private var selectedProjectID: UUID?
    @State private var selectedToolID: UUID?
    @State private var selectedModel: AgentModelOption = .auto
    @State private var attachments: [PromptAttachment] = []
    @State private var selectedSessionID: UUID?
    @State private var errorMessage: String?
    @State private var isLaunching = false
    @State private var pasteMonitor: Any?
    @State private var showProjectPicker = false
    @FocusState private var promptFocused: Bool

    @StateObject private var fileMentions = FileMentionIndex()
    @StateObject private var voice = VoiceDictationService()
    @StateObject private var chat = ChatService()
    @StateObject private var chatHistory = ChatHistoryStore()
    @StateObject private var board = BoardStore()
    /// ⌘1 chat / ⌘2 agent / ⌘N board; restored from settings and persisted on change.
    @State private var mode: LauncherMode = .agent
    /// Keep ChatModeView (and its WKWebViews) mounted after first visit so agent↔chat is instant.
    @State private var keepChatMounted = false
    @State private var mentionQuery: PromptMentionQuery?
    @State private var mentionResults: [FileMentionItem] = []
    @State private var mentionSelection = 0
    @State private var mentionVisible = false
    @State private var voiceError: String?
    @State private var showDictationOffAlert = false

    /// → expands the panel into a full local Ghostty terminal.
    @State private var isSessionPreviewOpen = false

    /// Prompt editor hugs its text (single line ≈ 24pt, grows to 72pt).
    @State private var promptHeight: CGFloat = 24
    /// Tab-cycled keyboard focus over the header controls.
    @State private var focusedControl: HeaderControl?
    /// Position while walking promptHistory with ↑/↓ (nil = not navigating).
    @State private var historyIndex: Int?
    /// True once ↑/↓ started moving the session-tab selection — arrows then
    /// stay in the tab list instead of jumping into prompt history.
    @State private var isNavigatingTabs = false
    @State private var showBoardToast = false

    enum HeaderControl: Int, CaseIterable {
        case project, tool, model, attach
        case workspace, boardProject, column
    }

    private var headerControlsForMode: [HeaderControl] {
        switch mode {
        case .chat: return [.attach]
        case .agent: return [.project, .tool, .model, .attach]
        case .board: return [.workspace, .boardProject, .column, .attach]
        }
    }

    private var selectedProject: ProjectFolder? {
        if let selectedProjectID {
            return settings.projects.first { $0.id == selectedProjectID }
        }
        return settings.projects.first
    }

    private var selectedTool: ToolConfig? {
        settings.tool(for: selectedToolID ?? settings.defaultToolID)
    }

    /// The middle session area only earns its height when there is something
    /// to show (sessions, setup steps, the chat thread) or an overlay needs
    /// room to render.
    private var showsContentArea: Bool {
        if mode == .chat || mode == .board { return true }
        if keepChatMounted, !chat.messages.isEmpty { return true }
        if isSessionPreviewOpen { return true }
        return !sessions.sessions.isEmpty || settings.needsSetup || mentionVisible || showProjectPicker
    }

    var body: some View {
        ZStack {
            // Keep Ghostty surfaces mounted for the life of each PTY so leaving
            // the preview (chat mode, Back, etc.) does not wipe scrollback.
            if !sessions.terminals.sessions.isEmpty {
                persistentTerminalLayer
                    .opacity(isSessionPreviewOpen ? 1 : 0)
                    .allowsHitTesting(isSessionPreviewOpen)
                    .accessibilityHidden(!isSessionPreviewOpen)
            }

            if isSessionPreviewOpen, let session = previewedSession {
                fullTerminalChrome(session)
            } else {
                VStack(spacing: 0) {
                    header
                    if !attachments.isEmpty {
                        Divider().opacity(0.2)
                        attachmentStrip
                    }
                    if showsContentArea {
                        Divider().opacity(0.25)
                        content
                    }
                    Divider().opacity(0.25)
                    footer
                }
            }
        }
        .frame(width: isSessionPreviewOpen ? 1180 : 720)
        .frame(height: isSessionPreviewOpen ? 780 : (showsContentArea ? 480 : nil))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: LauncherPanelSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(LauncherPanelSizeKey.self) { size in
            guard size.height > 0 else { return }
            NotificationCenter.default.post(
                name: .fastqLauncherPanelSizeChanged,
                object: nil,
                userInfo: ["height": size.height, "width": size.width]
            )
        }
        .background(LauncherBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if showProjectPicker {
                projectPickerOverlay
            }
        }
        .overlay(alignment: .topLeading) {
            if mentionVisible {
                mentionPopup
                    .padding(.leading, 46)
                    .padding(.top, 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            if showBoardToast {
                Text(auth.isLoggedIn ? "Opening Boards…" : "Sign in to use Boards")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 52)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .onAppear {
            bootstrapSelection()
            chat.bind(historyStore: chatHistory)
            chat.resetIfInactive()
            if mode == .chat || !chat.messages.isEmpty {
                keepChatMounted = true
            }
            focusPromptSoon()
            installKeyMonitors()
            refreshMentionIndex()
            voice.prepare()
            if mode == .board, auth.isLoggedIn {
                Task { await board.bootstrap() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastqFocusLauncherPrompt)) { _ in
            chat.resetIfInactive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastqOpenSessionPreview)) { note in
            if let id = note.object as? UUID {
                selectedSessionID = id
            }
            openSessionPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastqOpenShellPreview)) { _ in
            openShellInPreview()
        }
        .onDisappear {
            removeKeyMonitors()
        }
        .onChange(of: sessions.sessions) { _, newValue in
            if let selectedSessionID, !newValue.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = newValue.first?.id
            } else if selectedSessionID == nil {
                selectedSessionID = newValue.first?.id
            }
        }
        .onChange(of: showProjectPicker) { _, isOpen in
            LauncherKeyRouter.shared.isProjectPickerOpen = isOpen
            if !isOpen {
                focusPromptSoon()
            }
        }
        .onChange(of: selectedProjectID) { _, _ in
            refreshMentionIndex()
        }
        .onChange(of: settings.projects) { _, _ in
            refreshMentionIndex()
        }
        .onChange(of: fileMentions.results) { _, newValue in
            mentionResults = newValue
            if mentionSelection >= newValue.count {
                mentionSelection = max(0, newValue.count - 1)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $board.showNewProjectSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New project")
                    .font(.headline)
                TextField("Project name", text: $board.newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await board.createProject(name: board.newProjectName) }
                    }
                HStack {
                    Spacer()
                    Button("Cancel") { board.showNewProjectSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        Task { await board.createProject(name: board.newProjectName) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(board.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .alert("Voice input", isPresented: Binding(
            get: { voiceError != nil },
            set: { if !$0 { voiceError = nil } }
        )) {
            Button("OK", role: .cancel) { voiceError = nil }
        } message: {
            Text(voiceError ?? "")
        }
        .alert("Turn on Dictation", isPresented: $showDictationOffAlert) {
            Button("Open System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fastq dictation uses Apple speech recognition, which macOS only allows when Siri or Dictation is enabled. Turn on Dictation in System Settings → Keyboard, then try the mic again.")
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if loggedIn, mode == .board {
                Task { await board.bootstrap() }
            }
        }
        .onChange(of: voice.phase) { _, phase in
            if case .failed(let message) = phase {
                if message == VoiceDictationService.dictationDisabledMessage {
                    showDictationOffAlert = true
                } else {
                    voiceError = message
                }
            }
        }
        .onChange(of: prompt) { _, newValue in
            // Editing a recalled prompt exits history navigation.
            if let index = historyIndex,
               !settings.promptHistory.indices.contains(index) || newValue != settings.promptHistory[index] {
                historyIndex = nil
            }
            // Typing pulls the arrows back to the prompt/caret.
            if !newValue.isEmpty, historyIndex == nil {
                isNavigatingTabs = false
            }
        }
    }

    // MARK: - Mode switch (⌘1 chat / ⌘2 agent / ⌘N board)

    /// Leading prompt icon doubles as the mode indicator. Click cycles; shortcuts jump.
    private var modeIcon: some View {
        Button {
            switchMode(to: mode.next)
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 24, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mode: \(mode.accessibilityLabel) — ⌘1 Chat · ⌘2 Agent · ⌘N Projects")
        .accessibilityLabel(mode.accessibilityLabel)
    }

    private func switchMode(to target: LauncherMode) {
        guard mode != target else { return }
        if target == .chat || target == .board, isSessionPreviewOpen {
            closeSessionPreview()
        }
        if target == .chat {
            keepChatMounted = true
        }
        // Avoid animating the whole content tree — chat WKWebViews stay mounted.
        mode = target
        settings.launcherMode = target
        focusedControl = nil
        if target == .chat {
            chat.resetIfInactive()
        }
        if target == .board, auth.isLoggedIn {
            Task { await board.bootstrap() }
        }
        focusPromptSoon()
    }

    /// Chat toolbar “New” — archive the current thread (if any) and start a blank chat.
    private func startNewChat() {
        chat.startNewChat(persistCurrent: true)
        prompt = ""
        attachments = []
        keepChatMounted = true
        if mode != .chat {
            switchMode(to: .chat)
        } else {
            focusPromptSoon()
        }
    }

    /// Chat mode's counterpart to the tool/model chips: provider + model menu.
    private var chatModelChip: some View {
        Menu {
            ForEach(ChatProvider.allCases) { provider in
                Section(provider.displayName) {
                    ForEach(provider.models, id: \.id) { model in
                        Button {
                            settings.chatProvider = provider
                            switch provider {
                            case .anthropic: settings.anthropicChatModel = model.id
                            case .openai: settings.openAIChatModel = model.id
                            }
                        } label: {
                            if settings.chatProvider == provider, settings.chatModel == model.id {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("API Keys…") { onOpenSettings() }
        } label: {
            ChipLabel(
                systemIcon: "sparkles",
                title: settings.chatProvider.displayName(forModel: settings.chatModel),
                isActive: false
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chat model")
        .accessibilityLabel("Chat model: \(settings.chatProvider.displayName(forModel: settings.chatModel))")
    }

    // MARK: - Voice

    private var voiceButton: some View {
        Button {
            // Click still works as a toggle for accessibility / trackpad users.
            if voice.isListening {
                voice.endHold()
            } else if !voice.systemSpeechAvailable {
                // Re-check first — the user may have just flipped the toggle.
                voice.refreshSystemSpeechAvailability()
                if voice.systemSpeechAvailable {
                    voice.beginHold(currentPrompt: prompt) { prompt = $0 }
                } else {
                    showDictationOffAlert = true
                }
            } else {
                voice.beginHold(currentPrompt: prompt) { prompt = $0 }
            }
        } label: {
            ZStack {
                if voice.isListening {
                    VoicePulseRing(level: voice.level)
                }
                Image(systemName: voice.systemSpeechAvailable ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        voice.isListening
                            ? Color.accentColor
                            : (voice.systemSpeechAvailable ? Color.secondary : Color.red.opacity(0.7))
                    )
                    .scaleEffect(voice.isListening ? 1 + CGFloat(voice.level) * 0.2 : 1)
                    .animation(.easeOut(duration: 0.08), value: voice.level)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(showProjectPicker || {
            if case .requestingAccess = voice.phase { return true }
            return false
        }())
        .help(voiceHelp)
        .padding(.top, 0)
    }

    private var voiceHelp: String {
        if !voice.systemSpeechAvailable {
            return "Dictation is off in macOS — click for how to enable it"
        }
        switch voice.phase {
        case .listening:
            return "Listening… click to finish"
        case .requestingAccess:
            return "Starting microphone…"
        case .failed(let message):
            return message
        default:
            return "Dictate (live speech → text)"
        }
    }

    private var listeningBanner: some View {
        HStack(spacing: 10) {
            VoiceWaveform(level: voice.level)
                .frame(width: 56, height: 18)
            Text(voice.liveTranscript.isEmpty ? "Listening…" : voice.liveTranscript)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("click mic to stop")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                )
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                modeIcon

                PromptEditor(
                    text: $prompt,
                    placeholder: promptPlaceholder,
                    isEnabled: !showProjectPicker,
                    isFocused: promptFocused && !showProjectPicker,
                    mentionActive: mentionVisible,
                    isDictating: voice.isListening,
                    onSubmit: submitPrimary,
                    onMentionQueryChange: handleMentionQuery,
                    onMentionNavigate: { delta in
                        guard !mentionResults.isEmpty else { return }
                        let count = mentionResults.count
                        mentionSelection = ((mentionSelection + delta) % count + count) % count
                    },
                    onMentionConfirm: confirmMention,
                    onMentionCancel: {
                        mentionVisible = false
                        LauncherKeyRouter.shared.isMentionPopupOpen = false
                        mentionQuery = nil
                    },
                    onHeightChange: { height in
                        let clamped = min(max(height, 24), 72)
                        if abs(clamped - promptHeight) > 0.5 {
                            promptHeight = clamped
                        }
                    }
                )
                .frame(height: promptHeight)

                // Attach + mic + submit sit together as one cluster.
                HStack(spacing: 2) {
                    attachButton
                    voiceButton
                    submitButton
                }
                .frame(height: 24)
            }

            if voice.isListening {
                listeningBanner
            }

            HStack(spacing: 6) {
                switch mode {
                case .chat:
                    chatModelChip
                case .agent:
                    projectChip
                        .controlFocusRing(focusedControl == .project)
                        .accessibilityLabel("Project: \(selectedProject?.name ?? "none")")
                    toolMenu
                        .controlFocusRing(focusedControl == .tool)
                        .accessibilityLabel("Agent: \(selectedTool?.displayName ?? "none")")
                    modelMenu
                        .controlFocusRing(focusedControl == .model)
                        .accessibilityLabel("Model: \(selectedModel.displayName)")
                case .board:
                    workspaceChip
                        .controlFocusRing(focusedControl == .workspace)
                        .accessibilityLabel("Workspace: \(board.selectedWorkspace?.name ?? "none")")
                    boardProjectChip
                        .controlFocusRing(focusedControl == .boardProject)
                        .accessibilityLabel("Project: \(board.selectedProject?.name ?? "none")")
                    columnChip
                        .controlFocusRing(focusedControl == .column)
                        .accessibilityLabel("Column: \(board.selectedColumn?.name ?? "none")")
                }

                if isLaunching, mode == .agent || mode == .board {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(mode == .board
                              ? "Creating task…"
                              : "Starting \(selectedTool?.displayName ?? "agent")…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                    .transition(.opacity)
                }

                Spacer(minLength: 0)
            }
            // Chips carry 8pt of inner pill padding — pull the row left so
            // the folder icon's visible edge lines up with the prompt column.
            .padding(.leading, -8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 7)
        .animation(.easeOut(duration: 0.15), value: isLaunching)
    }

    private var attachButton: some View {
        Button(action: pickAttachments) {
            HStack(spacing: 3) {
                Image(systemName: "paperclip")
                    .font(.system(size: 13, weight: .semibold))
                if !attachments.isEmpty {
                    Text("\(attachments.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(attachments.isEmpty ? Color.secondary : Color.accentColor)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, attachments.isEmpty ? 0 : 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlFocusRing(focusedControl == .attach)
        .help("Attach files — ⌘V pastes files from the clipboard")
        .accessibilityLabel("Attach files")
    }

    /// Plain → glyph; becomes a spinner while the agent (and, cold-start,
    /// the terminal itself) is spinning up so the wait reads as progress.
    private var submitButton: some View {
        Button(action: submitPrimary) {
            Group {
                if isLaunching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canGo ? Color.accentColor : Color.secondary.opacity(0.6))
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canGo || isLaunching)
        .help("Return to go · Shift+Return for a new line")
        .accessibilityLabel(isLaunching ? "Launching…" : "Go")
    }

    private var canGo: Bool {
        if showProjectPicker { return false }
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch mode {
        case .chat:
            return hasPrompt && !chat.isStreaming
        case .board:
            if isLaunching { return false }
            return hasPrompt && auth.isLoggedIn && board.selectedProject != nil
        case .agent:
            if isLaunching { return false }
            let hasSession = selectedSessionID != nil
            return hasPrompt || hasSession
        }
    }

    private var promptPlaceholder: String {
        switch mode {
        case .chat: return "Ask anything…"
        case .agent: return "Ask an agent…  @ for files"
        case .board: return "Create a task…"
        }
    }

    private var projectChip: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                showProjectPicker.toggle()
                LauncherKeyRouter.shared.isProjectPickerOpen = showProjectPicker
            }
        } label: {
            ChipLabel(
                systemIcon: "folder.fill",
                title: selectedProject?.name ?? "Project",
                isActive: showProjectPicker
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: [.command])
        .help("Choose project (⌘P)")
    }

    private var projectPickerOverlay: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showProjectPicker = false
                    }
                    promptFocused = true
                }

            ProjectPickerView(
                projects: settings.projects,
                recentIDs: settings.recentProjectIDs,
                selectedID: selectedProjectID,
                onSelect: { project in
                    selectedProjectID = project.id
                    settings.markProjectUsed(project)
                    closeProjectPicker()
                },
                onAdd: {
                    addProjectFolders()
                },
                onManage: {
                    showProjectPicker = false
                    onOpenSettings()
                },
                onDismiss: {
                    closeProjectPicker()
                }
            )
            .padding(.leading, 18)
            .padding(.top, 72)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolMenu: some View {
        Menu {
            ForEach(settings.enabledTools) { tool in
                Button {
                    selectedToolID = tool.id
                } label: {
                    Label {
                        Text(tool.displayName)
                    } icon: {
                        AgentBrandIcon(kind: tool.kind, size: 12)
                    }
                }
            }
        } label: {
            ChipLabel(
                brand: selectedTool?.kind,
                systemIcon: selectedTool?.kind.systemImage ?? "hammer",
                title: selectedTool?.displayName ?? "Tool"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modelMenu: some View {
        Menu {
            ForEach(AgentModelOption.allCases) { model in
                Button {
                    selectedModel = model
                } label: {
                    Text(model.displayName)
                }
            }
        } label: {
            ChipLabel(systemIcon: "cpu", title: selectedModel.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var workspaceChip: some View {
        Menu {
            if board.workspaces.isEmpty {
                Text("No workspaces")
            } else {
                ForEach(board.workspaces) { ws in
                    Button {
                        Task { await board.selectWorkspace(ws.id) }
                    } label: {
                        if board.selectedWorkspaceID == ws.id {
                            Label(ws.name, systemImage: "checkmark")
                        } else {
                            Text(ws.name)
                        }
                    }
                }
            }
        } label: {
            ChipLabel(
                systemIcon: "building.2",
                title: board.selectedWorkspace?.name ?? "Workspace",
                isActive: focusedControl == .workspace
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!auth.isLoggedIn || board.workspaces.isEmpty)
        .help("Workspace")
    }

    private var boardProjectChip: some View {
        Menu {
            if board.projects.isEmpty {
                Text("No projects")
            } else {
                ForEach(board.projects) { project in
                    Button {
                        Task { await board.selectProject(project.id) }
                    } label: {
                        if board.selectedProjectID == project.id {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            }
            Divider()
            Button("New project…") {
                board.showNewProjectSheet = true
            }
            Button("Open Boards…") { openBoards() }
        } label: {
            ChipLabel(
                systemIcon: "folder.fill",
                title: board.selectedProject?.name ?? "Project",
                isActive: focusedControl == .boardProject
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!auth.isLoggedIn)
        .help("Project")
    }

    private var columnChip: some View {
        Menu {
            let columns = (board.board?.columns ?? []).sorted { $0.position < $1.position }
            if columns.isEmpty {
                Text("No columns")
            } else {
                ForEach(columns) { column in
                    Button {
                        board.selectColumn(column.id)
                    } label: {
                        if board.selectedColumnID == column.id {
                            Label(column.name, systemImage: "checkmark")
                        } else {
                            Text(column.name)
                        }
                    }
                }
            }
        } label: {
            ChipLabel(
                systemIcon: "rectangle.split.3x1",
                title: board.selectedColumn?.name ?? "Column",
                isActive: focusedControl == .column
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(board.board?.columns.isEmpty != false)
        .help("Board column")
    }

    private var mentionPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if fileMentions.isIndexing {
                    ProgressView().controlSize(.mini)
                    Text("indexing…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if fileMentions.indexedCount > 0 {
                    Text("\(fileMentions.indexedCount)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                Spacer()
                Text("↵ select · fuzzy")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(mentionResults.prefix(12).enumerated()), id: \.element.id) { index, item in
                        Button {
                            mentionSelection = index
                            confirmMention()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text("\(item.projectName) · \(item.relativePath)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(index == mentionSelection ? Color.white.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if mentionResults.isEmpty, !fileMentions.isIndexing {
                        Text(mentionQuery?.filter.isEmpty == false ? "No matches" : "Type to fuzzy-find files…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 220)
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        )
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        } else {
                            Image(systemName: attachment.isImage ? "photo" : "doc")
                                .font(.caption)
                        }
                        Text(attachment.name)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Content

    private var content: some View {
        ZStack {
            // Agent sessions / empty — only interactive in agent mode.
            Group {
                if sessions.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .opacity(mode == .agent ? 1 : 0)
            .allowsHitTesting(mode == .agent)
            .accessibilityHidden(mode != .agent)

            BoardModeView(
                store: board,
                auth: auth,
                onSignIn: {
                    if let onOpenAccountSettings {
                        onOpenAccountSettings()
                    } else {
                        onOpenSettings()
                    }
                },
                onOpenBoards: openBoards
            )
            .opacity(mode == .board ? 1 : 0)
            .allowsHitTesting(mode == .board)
            .accessibilityHidden(mode != .board)

            // Keep chat mounted after first open so agent→chat doesn't remount WKWebViews.
            if keepChatMounted || mode == .chat {
                ChatModeView(
                    chat: chat,
                    history: chatHistory,
                    providerName: settings.chatProvider.displayName,
                    modelName: settings.chatProvider.displayName(forModel: settings.chatModel),
                    onNewChat: startNewChat
                )
                .opacity(mode == .chat ? 1 : 0)
                .allowsHitTesting(mode == .chat)
                .accessibilityHidden(mode != .chat)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Full terminal (→ / ↩ / after launch)

    private var previewedSession: AgentSession? {
        sessions.sessions.first(where: { $0.id == selectedSessionID })
    }

    /// Chrome only — surfaces live in `persistentTerminalLayer` underneath.
    private func fullTerminalChrome(_ session: AgentSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: closeSessionPreview) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the list (← / esc)")

                Image(systemName: session.tool.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(session.status == .running ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(session.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("↑↓ switch · esc back")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Button {
                    launcher.quit(session)
                    closeSessionPreview()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Quit session")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().opacity(0.2)

            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Stable Ghostty host stack — must stay in the view tree so remounting
    /// does not drop PTY scrollback (receive requires a live surface).
    private var persistentTerminalLayer: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: isSessionPreviewOpen ? 45 : 0)
            ZStack {
                Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)

                ForEach(sessions.terminals.sessions) { terminal in
                    let isSelected = terminal.id == selectedSessionID
                    GhosttyTerminalHost(
                        session: terminal,
                        isActive: isSelected && isSessionPreviewOpen
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected && isSessionPreviewOpen)
                    .id(terminal.id)
                }

                if let selectedSessionID, sessions.terminal(id: selectedSessionID) == nil {
                    Text("Starting terminal…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openSessionPreview() {
        guard mode == .agent, let session = previewedSession else { return }
        sessions.terminals.select(session.id)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            isSessionPreviewOpen = true
        }
        LauncherKeyRouter.shared.isSessionPreviewOpen = true
    }

    private func closeSessionPreview() {
        LauncherKeyRouter.shared.isSessionPreviewOpen = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            isSessionPreviewOpen = false
        }
        focusPromptSoon()
    }

    private var emptyState: some View {
        Group {
            if settings.projects.isEmpty || !settings.hasCompletedOnboarding {
                setupEmptyState
            } else {
                idleEmptyState
            }
        }
    }

    private var setupEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color(red: 0.95, green: 0.36, blue: 0.28))
                .opacity(0.95)

            Text(settings.projects.isEmpty ? "Add a project to get started" : "Finish setup")
                .font(.headline)

            Text(settings.projects.isEmpty
                 ? "Fastq needs at least one folder so agents know where to work."
                 : "A couple of steps left — projects, tools, and window access.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 10) {
                Button {
                    onOpenOnboarding?()
                } label: {
                    Text(settings.hasCompletedOnboarding ? "Add projects" : "Continue setup")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(.black.opacity(0.88))
                }
                .buttonStyle(.plain)

                Button("Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var idleEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No active agent windows")
                .font(.headline)
            Text("Launch Cursor, Claude Code, or Codex and they’ll appear here so you can jump back or quit them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 6) {
                Text("Tip:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("⌘V attaches files from the clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("→ open")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sessions.sessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: selectedSessionID == session.id,
                            onSelect: { selectedSessionID = session.id },
                            onFocus: {
                                selectedSessionID = session.id
                                openSessionPreview()
                            },
                            onQuit: {
                                launcher.quit(session)
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            accountItem

            Spacer()

            if let session = sessions.sessions.first(where: { $0.id == selectedSessionID }) {
                FooterAction(title: "Open", key: "↩") {
                    openSessionPreview()
                }
                FooterAction(title: "Quit", key: "⌫") {
                    launcher.quit(session)
                }
                Divider().frame(height: 14)
            }

            FooterAction(title: "Board", key: "⌘B", action: openBoards)
            FooterAction(title: "Settings", key: "⌘,") {
                onOpenSettings()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.18))
    }

    /// Bottom-left account slot — Fastplay account when signed in.
    @ViewBuilder
    private var accountItem: some View {
        if auth.isLoggedIn, let user = auth.user {
            Menu {
                Button("Boards") { openBoards() }
                Button("Account Settings…") {
                    if let onOpenAccountSettings {
                        onOpenAccountSettings()
                    } else {
                        onOpenSettings()
                    }
                }
                Divider()
                Button("Sign Out") {
                    Task { await auth.logout() }
                }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.85))
                        Text(user.initials)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 18, height: 18)
                    Text(user.name.isEmpty ? user.email : user.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Account: \(user.name)")
        } else {
            Button {
                if let onOpenAccountSettings {
                    onOpenAccountSettings()
                } else {
                    onOpenSettings()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 13))
                    Text("Log in")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Log in")
        }
    }

    private func openBoards() {
        if auth.isLoggedIn {
            onOpenBoards?()
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                showBoardToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeIn(duration: 0.2)) {
                    showBoardToast = false
                }
                onOpenAccountSettings?()
                if onOpenAccountSettings == nil {
                    onOpenSettings()
                }
            }
        }
    }

    private func showBoardPlaceholder() {
        openBoards()
    }

    // MARK: - Actions

    private func submitPrimary() {
        if showProjectPicker { return }
        switch mode {
        case .chat:
            sendChatMessage()
        case .board:
            Task { await createBoardTask() }
        case .agent:
            if sessions.sessions.contains(where: { $0.id == selectedSessionID }),
               prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                openSessionPreview()
                return
            }
            settings.recordPrompt(prompt)
            historyIndex = nil
            Task { await launchAgent() }
        }
    }

    private func createBoardTask() async {
        let title = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard auth.isLoggedIn else {
            errorMessage = "Sign in to create tasks."
            return
        }
        guard board.selectedProject != nil else {
            errorMessage = "Pick a workspace and project first."
            return
        }
        isLaunching = true
        defer { isLaunching = false }
        settings.recordPrompt(prompt)
        historyIndex = nil
        let files = attachments.map { URL(fileURLWithPath: $0.path) }
        do {
            _ = try await board.createTaskFromLauncher(
                title: title,
                columnID: board.selectedColumnID,
                attachmentURLs: files
            )
            prompt = ""
            attachments = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendChatMessage() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isStreaming else { return }
        let apiKey = settings.chatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = "Add your \(settings.chatProvider.displayName) API key in Settings → Chat first."
            return
        }
        settings.recordPrompt(prompt)
        historyIndex = nil
        chat.send(
            text: text,
            attachments: attachments,
            provider: settings.chatProvider,
            model: settings.chatModel,
            apiKey: apiKey
        )
        prompt = ""
        attachments = []
    }

    private func bootstrapSelection() {
        mode = settings.launcherMode
        if mode == .chat || !chat.messages.isEmpty {
            keepChatMounted = true
        }
        if let recent = settings.recentProjectIDs.first,
           settings.projects.contains(where: { $0.id == recent }) {
            selectedProjectID = recent
        } else {
            selectedProjectID = settings.projects.first?.id
        }
        selectedToolID = settings.defaultToolID ?? settings.enabledTools.first?.id
        selectedModel = settings.defaultModel
        selectedSessionID = sessions.sessions.first?.id
    }

    /// Refocus the prompt. With `caret` the cursor lands there (mention
    /// insert); without it the existing text is selected (fresh summon).
    private func focusPromptSoon(caret: Int? = nil) {
        promptFocused = true
        let userInfo: [String: Any] = caret.map { ["caret": $0] } ?? [:]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .fastqFocusLauncherPrompt, object: nil, userInfo: userInfo)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.promptFocused = true
            NotificationCenter.default.post(name: .fastqFocusLauncherPrompt, object: nil, userInfo: userInfo)
        }
    }

    private func closeProjectPicker() {
        withAnimation(.easeOut(duration: 0.15)) {
            showProjectPicker = false
        }
        focusPromptSoon()
    }

    private func launchAgent() async {
        guard !isLaunching else { return }
        guard let project = selectedProject else {
            errorMessage = AgentLaunchError.missingProject.localizedDescription
            return
        }
        guard let tool = selectedTool else {
            errorMessage = AgentLaunchError.missingTool.localizedDescription
            return
        }

        isLaunching = true
        defer { isLaunching = false }

        do {
            let session = try launcher.launch(
                prompt: prompt,
                project: project,
                tool: tool,
                model: selectedModel,
                attachments: attachments,
                extraProjectPaths: settings.projects.map(\.path)
            )
            settings.markProjectUsed(project)
            selectedSessionID = session.id
            prompt = ""
            attachments = []
            openSessionPreview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// ⌘T — open a plain shell in the launcher terminal.
    /// Reuses an existing shell when one is already running; no-ops if the
    /// terminal preview is already open.
    private func openShellInPreview() {
        if isSessionPreviewOpen { return }

        if let existing = existingShellTerminal() {
            sessions.terminals.select(existing.id)
            selectedSessionID = existing.id
            sessions.upsertFromTerminal(existing)
            openSessionPreview()
            return
        }

        let path = selectedProject?.path ?? NSHomeDirectory()
        guard let terminal = sessions.terminals.createShellSession(at: path) else {
            errorMessage = "Couldn’t start a terminal."
            return
        }
        sessions.upsertFromTerminal(terminal)
        selectedSessionID = terminal.id
        openSessionPreview()
    }

    /// Prefer the selected shell, otherwise the most recently created shell tab.
    private func existingShellTerminal() -> TerminalSession? {
        let shells = sessions.terminals.sessions.filter { $0.isShell || $0.isFallbackShell }
        guard !shells.isEmpty else { return nil }
        if let selectedSessionID,
           let selected = shells.first(where: { $0.id == selectedSessionID }) {
            return selected
        }
        return shells.last
    }

    private func addProjectFolders() {
        FolderPicker.chooseDirectories { urls in
            guard !urls.isEmpty else { return }
            var lastAdded: ProjectFolder?
            for url in urls {
                lastAdded = settings.addProjectReturning(url.path) ?? lastAdded
            }
            if let lastAdded {
                selectedProjectID = lastAdded.id
                settings.markProjectUsed(lastAdded)
            }
            // Picker stays open; Esc still dismisses it.
        }
    }

    private func pickAttachments() {
        FolderPicker.chooseFiles { urls in
            guard !urls.isEmpty else { return }
            addAttachments(urls)
        }
    }

    private func addAttachments(_ urls: [URL]) {
        for url in urls {
            if !attachments.contains(where: { $0.path == url.path }) {
                attachments.append(PromptAttachment(url: url))
            }
        }
    }

    private func installKeyMonitors() {
        removeKeyMonitors()

        let pickerBinding = $showProjectPicker
        let mentionVisibleBinding = $mentionVisible
        let mentionQueryBinding = $mentionQuery
        let mentionResultsBinding = $mentionResults
        LauncherKeyRouter.shared.isProjectPickerOpen = showProjectPicker
        LauncherKeyRouter.shared.closePicker = {
            pickerBinding.wrappedValue = false
        }
        LauncherKeyRouter.shared.closeMentionPopup = {
            mentionVisibleBinding.wrappedValue = false
            LauncherKeyRouter.shared.isMentionPopupOpen = false
            mentionQueryBinding.wrappedValue = nil
            mentionResultsBinding.wrappedValue = []
            fileMentions.clearResults()
        }
        LauncherKeyRouter.shared.attachFiles = { [attachments = $attachments] urls in
            var current = attachments.wrappedValue
            for url in urls where !current.contains(where: { $0.path == url.path }) {
                current.append(PromptAttachment(url: url))
            }
            attachments.wrappedValue = current
        }

        LauncherKeyRouter.shared.clearControlFocus = { [focusedControl = $focusedControl] in
            guard focusedControl.wrappedValue != nil else { return false }
            focusedControl.wrappedValue = nil
            LauncherKeyRouter.shared.focusPromptNow?()
            return true
        }

        LauncherKeyRouter.shared.closeSessionPreview = {
            closeSessionPreview()
        }

        // Keyboard model (Esc itself is owned by LauncherPanelController):
        //   Tab / ⇧Tab   cycle header controls
        //   focused chip: ←→↑↓ change its value, Return/Space activates,
        //                 any printable key falls through to the prompt
        //   ↑ / ↓        prompt history ↔ session-tab selection
        //   ⌘1/2/N(or 3) Chat / Agent / Projects · ⌘B Boards · ⌘V attach
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The panel hides via orderOut, so onDisappear never removes this
            // monitor — without this gate it hijacks keystrokes in every other
            // window (Settings, onboarding): the type-anywhere branch steals
            // key status back to the hidden launcher on each printable key.
            guard LauncherKeyRouter.shared.isLauncherVisible,
                  event.window is NSPanel else { return event }
            guard !LauncherKeyRouter.shared.isProjectPickerOpen else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if mods == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "1":
                    DispatchQueue.main.async { switchMode(to: .chat) }
                    return nil
                case "2":
                    DispatchQueue.main.async { switchMode(to: .agent) }
                    return nil
                case "3", "n":
                    DispatchQueue.main.async { switchMode(to: .board) }
                    return nil
                case "b":
                    DispatchQueue.main.async { openBoards() }
                    return nil
                case "v":
                    let pb = NSPasteboard.general
                    if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
                        .urlReadingFileURLsOnly: true
                    ]) as? [URL], !urls.isEmpty {
                        DispatchQueue.main.async {
                            LauncherKeyRouter.shared.attachFiles?(urls)
                        }
                        return nil
                    }
                    // Raw image data (screenshots, copied images) → temp PNG.
                    if let imageURL = Self.pastedImageURL(from: pb) {
                        DispatchQueue.main.async {
                            LauncherKeyRouter.shared.attachFiles?([imageURL])
                        }
                        return nil
                    }
                    return event
                default:
                    return event
                }
            }

            // Interactive terminal mirror owns keys while it's first responder
            // (so agents can take typed replies). Esc still closes via the panel.
            if LauncherKeyRouter.shared.isSessionPreviewOpen,
               event.window?.firstResponder is FastqSurfaceView {
                return event
            }

            // Tab cycles header controls (mention popup owns Tab to confirm).
            if event.keyCode == 48, mods.isEmpty || mods == .shift {
                if LauncherKeyRouter.shared.isMentionPopupOpen { return event }
                cycleControlFocus(backwards: mods == .shift)
                return nil
            }

            // Keys owned by the Tab-focused chip.
            if let control = focusedControl, mods.isEmpty || mods == .shift {
                switch event.keyCode {
                case 36, 76, 49: // Return / Enter / Space → activate
                    activateControl(control)
                    return nil
                case 123, 126: // ← ↑ previous value
                    adjustControl(control, by: -1)
                    return nil
                case 124, 125: // → ↓ next value
                    adjustControl(control, by: 1)
                    return nil
                default:
                    // Printable key → hand focus back to the prompt and let
                    // the keystroke land there (type-anywhere).
                    if isPrintable(event) {
                        focusedControl = nil
                        LauncherKeyRouter.shared.focusPromptNow?()
                    }
                    return event
                }
            }

            // ← folds the session preview back into the list (when not typing).
            if event.keyCode == 123, mods.isEmpty, LauncherKeyRouter.shared.isSessionPreviewOpen {
                DispatchQueue.main.async { closeSessionPreview() }
                return nil
            }

            // → on the session list expands into the live interactive terminal.
            if event.keyCode == 124, mods.isEmpty,
               mode == .agent,
               !LauncherKeyRouter.shared.isSessionPreviewOpen,
               !LauncherKeyRouter.shared.isMentionPopupOpen,
               selectedSessionID != nil,
               isNavigatingTabs || prompt.isEmpty {
                DispatchQueue.main.async { openSessionPreview() }
                return nil
            }

            // ↑ / ↓ — prompt history, then session tabs (mention popup owns these).
            if event.keyCode == 125 || event.keyCode == 126 {
                if LauncherKeyRouter.shared.isMentionPopupOpen { return event }
                return handleArrowKey(up: event.keyCode == 126) ? nil : event
            }

            // Type-anywhere: printable keys refocus the prompt, then land in it.
            if mods.isEmpty || mods == .shift,
               isPrintable(event),
               !(event.window?.firstResponder is PromptNSTextView) {
                LauncherKeyRouter.shared.focusPromptNow?()
                return event
            }

            return event
        }
    }

    /// Writes clipboard image data (screenshot, copied image) to a temp PNG
    /// so it can ride the existing file-attachment path.
    private static func pastedImageURL(from pb: NSPasteboard) -> URL? {
        var data: Data?
        if let png = pb.data(forType: .png) {
            data = png
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pasted-\(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func isPrintable(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(scalar)
    }

    // MARK: - Header control focus (Tab cycle)

    private func cycleControlFocus(backwards: Bool) {
        let all = headerControlsForMode
        guard !all.isEmpty else { return }
        guard let current = focusedControl, let index = all.firstIndex(of: current) else {
            focusedControl = backwards ? all.last : all.first
            return
        }
        let next = index + (backwards ? -1 : 1)
        if all.indices.contains(next) {
            focusedControl = all[next]
        } else {
            focusedControl = nil
            LauncherKeyRouter.shared.focusPromptNow?()
        }
    }

    private func activateControl(_ control: HeaderControl) {
        switch control {
        case .project:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                showProjectPicker = true
                LauncherKeyRouter.shared.isProjectPickerOpen = true
            }
        case .tool, .model, .workspace, .boardProject, .column:
            adjustControl(control, by: 1)
        case .attach:
            pickAttachments()
        }
    }

    /// ←/→ (or ↑/↓) on a focused chip steps through its options in place.
    private func adjustControl(_ control: HeaderControl, by delta: Int) {
        func wrapped(_ index: Int, _ count: Int) -> Int {
            ((index + delta) % count + count) % count
        }
        switch control {
        case .project:
            let projects = settings.projects
            guard !projects.isEmpty else { return }
            let index = projects.firstIndex(where: { $0.id == selectedProjectID }) ?? 0
            let next = projects[wrapped(index, projects.count)]
            selectedProjectID = next.id
            settings.markProjectUsed(next)
        case .tool:
            let tools = settings.enabledTools
            guard !tools.isEmpty else { return }
            let index = tools.firstIndex(where: { $0.id == selectedToolID }) ?? 0
            selectedToolID = tools[wrapped(index, tools.count)].id
        case .model:
            let all = AgentModelOption.allCases
            let index = all.firstIndex(of: selectedModel) ?? 0
            selectedModel = all[wrapped(index, all.count)]
        case .workspace:
            let list = board.workspaces
            guard !list.isEmpty else { return }
            let index = list.firstIndex(where: { $0.id == board.selectedWorkspaceID }) ?? 0
            let next = list[wrapped(index, list.count)]
            Task { await board.selectWorkspace(next.id) }
        case .boardProject:
            let list = board.projects
            guard !list.isEmpty else { return }
            let index = list.firstIndex(where: { $0.id == board.selectedProjectID }) ?? 0
            let next = list[wrapped(index, list.count)]
            Task { await board.selectProject(next.id) }
        case .column:
            let list = (board.board?.columns ?? []).sorted { $0.position < $1.position }
            guard !list.isEmpty else { return }
            let index = list.firstIndex(where: { $0.id == board.selectedColumnID }) ?? 0
            board.selectColumn(list[wrapped(index, list.count)].id)
        case .attach:
            break
        }
    }

    // MARK: - Prompt history (↑) ↔ session tabs (↓)

    /// Shell-style recall that coexists with tab selection: ↑ walks history
    /// older (from an empty or recalled prompt), ↓ walks newer; stepping past
    /// the newest entry empties the prompt, and from an empty prompt ↓/↑
    /// cycle the active session tabs. While typing normal text the arrows
    /// stay with the caret. Returns true when the key was consumed.
    private func handleArrowKey(up: Bool) -> Bool {
        let history = settings.promptHistory
        if up {
            // Walking the tab list: ↑ steps to the previous tab. At the top
            // it detents (drops out of tab mode); the next ↑ opens history.
            if isNavigatingTabs {
                if selectedSessionID == sessions.sessions.first?.id {
                    isNavigatingTabs = false
                } else {
                    cycleActiveSessions(by: -1)
                }
                return true
            }
            if historyIndex == nil, !prompt.isEmpty { return false }
            if let index = historyIndex {
                if index > 0 {
                    recallHistory(at: index - 1)
                }
                return true
            }
            guard !history.isEmpty else {
                isNavigatingTabs = !sessions.sessions.isEmpty
                cycleActiveSessions(by: -1)
                return true
            }
            recallHistory(at: history.count - 1)
            return true
        } else {
            if let index = historyIndex {
                if index + 1 < history.count {
                    recallHistory(at: index + 1)
                } else {
                    // Past the newest entry → back to a fresh prompt; the
                    // next ↓ moves into the tab list below.
                    historyIndex = nil
                    prompt = ""
                }
                return true
            }
            if !prompt.isEmpty { return false }
            isNavigatingTabs = !sessions.sessions.isEmpty
            cycleActiveSessions(by: 1)
            return true
        }
    }

    private func recallHistory(at index: Int) {
        let history = settings.promptHistory
        guard history.indices.contains(index) else { return }
        isNavigatingTabs = false
        historyIndex = index
        prompt = history[index]
        focusPromptSoon(caret: history[index].utf16.count)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    LauncherKeyRouter.shared.attachFiles?([url])
                }
            }
        }
        return true
    }

    private func cycleActiveSessions(by delta: Int) {
        let list = sessions.sessions
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex(where: { $0.id == selectedSessionID }) ?? 0
        let count = list.count
        let nextIndex = ((currentIndex + delta) % count + count) % count
        let next = list[nextIndex]
        selectedSessionID = next.id
        launcher.selectTerminalTab(next.id)
    }

    private func removeKeyMonitors() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
    }

    // MARK: - @ file mentions

    private func refreshMentionIndex() {
        fileMentions.ensureIndexed(
            projects: settings.projects,
            primaryPath: selectedProject?.path
        )
    }

    private func handleMentionQuery(_ query: PromptMentionQuery?) {
        mentionQuery = query
        guard let query else {
            mentionVisible = false
            LauncherKeyRouter.shared.isMentionPopupOpen = false
            fileMentions.clearResults()
            mentionResults = []
            return
        }
        // Index once in background; never rescan on every keystroke.
        refreshMentionIndex()
        mentionVisible = true
        LauncherKeyRouter.shared.isMentionPopupOpen = true
        // Fuzzy search off the main thread; results arrive via onChange.
        fileMentions.query(query.filter, primaryPath: selectedProject?.path, limit: 40)
        // Keep prior selection stable while results refresh.
        if mentionResults.isEmpty {
            mentionSelection = 0
        }
    }

    private func confirmMention() {
        let list = fileMentions.results.isEmpty ? mentionResults : fileMentions.results
        guard mentionVisible,
              let query = mentionQuery,
              list.indices.contains(mentionSelection) else {
            mentionVisible = false
            LauncherKeyRouter.shared.isMentionPopupOpen = false
            return
        }
        let item = list[mentionSelection]
        let ns = prompt as NSString
        guard NSMaxRange(query.range) <= ns.length else {
            mentionVisible = false
            LauncherKeyRouter.shared.isMentionPopupOpen = false
            return
        }

        let insertion: String
        if let primary = selectedProject?.path, item.path.hasPrefix(primary + "/") {
            insertion = "@" + item.relativePath
        } else {
            insertion = "@\(item.projectName)/\(item.relativePath)"
        }

        let replaced = ns.replacingCharacters(in: query.range, with: insertion + " ")
        prompt = replaced
        mentionVisible = false
        LauncherKeyRouter.shared.isMentionPopupOpen = false
        mentionQuery = nil
        mentionResults = []
        fileMentions.clearResults()
        // Caret right after the inserted "@mention " so typing continues —
        // never select-all (a following keystroke would wipe the prompt).
        focusPromptSoon(caret: query.range.location + (insertion + " ").utf16.count)
    }
}

// MARK: - Rows & Chrome

private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onFocus: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 34, height: 34)
                AgentBrandIcon(kind: session.tool, size: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(session.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(session.status == .launching ? "Launching" : "Running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button(action: onQuit) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Quit this agent window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onFocus)
        .onTapGesture(perform: onSelect)
    }
}

private struct ChipLabel: View {
    var brand: AgentToolKind? = nil
    var systemIcon: String? = nil
    let title: String
    var isActive: Bool = false

    init(brand: AgentToolKind? = nil, systemIcon: String? = nil, icon: String? = nil, title: String, isActive: Bool = false) {
        self.brand = brand
        self.systemIcon = systemIcon ?? icon
        self.title = title
        self.isActive = isActive
    }

    var body: some View {
        HStack(spacing: 5) {
            if let brand {
                AgentBrandIcon(kind: brand, size: 10)
            } else if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.8)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .semibold))
                .rotationEffect(.degrees(isActive ? 180 : 0))
                .opacity(0.55)
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        // Quiet by default — a pill background only while its menu is open.
        .background(Color.white.opacity(isActive ? 0.13 : 0), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(isActive ? 0.2 : 0), lineWidth: 1)
        )
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

private struct LauncherPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension Notification.Name {
    /// SwiftUI content size changed — the panel resizes to fit (top-anchored).
    static let fastqLauncherPanelSizeChanged = Notification.Name("fastq.launcherPanelSizeChanged")
    /// Open the in-launcher interactive terminal for a session (object: UUID?).
    static let fastqOpenSessionPreview = Notification.Name("fastq.openSessionPreview")
    /// ⌘T — ensure a shell session and open the launcher preview.
    static let fastqOpenShellPreview = Notification.Name("fastq.openShellPreview")
}

/// Accent ring shown on the chip currently reachable via Tab.
private extension View {
    func controlFocusRing(_ active: Bool) -> some View {
        overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(active ? 0.9 : 0), lineWidth: 1.5)
                .padding(-2)
        )
        .animation(.easeOut(duration: 0.12), value: active)
    }
}

private struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.secondary)
    }
}

private struct FooterAction: View {
    let title: String
    let key: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct LauncherBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.12, blue: 0.18).opacity(0.35),
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: UnitPoint(x: 0.55, y: 0.45)
            )
            Color.black.opacity(0.22)
        }
    }
}

// MARK: - Voice animations

private struct VoicePulseRing: View {
    var level: Float

    var body: some View {
        Circle()
            .stroke(Color.accentColor.opacity(0.35 + Double(level) * 0.4), lineWidth: 2)
            .frame(width: 30 + CGFloat(level) * 14, height: 30 + CGFloat(level) * 14)
            .animation(.easeOut(duration: 0.1), value: level)
    }
}

private struct VoiceWaveform: View {
    var level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let offsets: [Float] = [0.35, 0.7, 1.0, 0.7, 0.35]
        let h = 4 + CGFloat(level * offsets[index]) * 14
        return max(4, min(18, h))
    }
}
