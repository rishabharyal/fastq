import SwiftUI
import AppKit

struct LauncherView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var sessions: SessionStore
    let launcher: AgentLauncher
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    var onOpenOnboarding: (() -> Void)? = nil

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
    @State private var mentionQuery: PromptMentionQuery?
    @State private var mentionResults: [FileMentionItem] = []
    @State private var mentionSelection = 0
    @State private var mentionVisible = false
    @State private var voiceError: String?

    private var selectedProject: ProjectFolder? {
        if let selectedProjectID {
            return settings.projects.first { $0.id == selectedProjectID }
        }
        return settings.projects.first
    }

    private var selectedTool: ToolConfig? {
        settings.tool(for: selectedToolID ?? settings.defaultToolID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            if !attachments.isEmpty {
                attachmentStrip
                Divider().opacity(0.2)
            }
            content
            Divider().opacity(0.25)
            footer
        }
        .frame(width: 720, height: 480)
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
        .onAppear {
            bootstrapSelection()
            focusPromptSoon()
            installKeyMonitors()
            refreshMentionIndex()
            voice.prepare()
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
        .alert("Couldn’t launch agent", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Voice input", isPresented: Binding(
            get: { voiceError != nil },
            set: { if !$0 { voiceError = nil } }
        )) {
            Button("OK", role: .cancel) { voiceError = nil }
        } message: {
            Text(voiceError ?? "")
        }
        .onChange(of: voice.phase) { _, phase in
            if case .failed(let message) = phase {
                voiceError = message
            }
        }
    }

    // MARK: - Voice

    private var voiceButton: some View {
        Button {
            // Click still works as a toggle for accessibility / trackpad users.
            if voice.isListening {
                voice.endHold()
            } else {
                voice.beginHold(currentPrompt: prompt) { prompt = $0 }
            }
        } label: {
            ZStack {
                if voice.isListening {
                    VoicePulseRing(level: voice.level)
                }
                Circle()
                    .fill(voice.isListening
                          ? Color.accentColor.opacity(0.9)
                          : Color.white.opacity(0.08))
                    .frame(width: 30, height: 30)
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(voice.isListening ? .white : .secondary)
                    .scaleEffect(voice.isListening ? 1 + CGFloat(voice.level) * 0.2 : 1)
                    .animation(.easeOut(duration: 0.08), value: voice.level)
            }
            .frame(width: 36, height: 36)
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
        switch voice.phase {
        case .listening:
            return "Listening… release Space to finish"
        case .requestingAccess:
            return "Starting microphone…"
        case .failed(let message):
            return message
        default:
            return "Hold Space to dictate (live speech → text)"
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
            Text("release Space")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)

                PromptEditor(
                    text: $prompt,
                    placeholder: "Ask an agent…  hold Space to talk · @ for files",
                    isEnabled: !showProjectPicker,
                    isFocused: promptFocused && !showProjectPicker,
                    mentionActive: mentionVisible,
                    spaceHoldEnabled: !showProjectPicker && !mentionVisible,
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
                    onSpaceHoldBegin: {
                        voice.beginHold(currentPrompt: prompt) { prompt = $0 }
                    },
                    onSpaceHoldEnd: {
                        voice.endHold()
                    },
                    onSpaceHoldCancel: {
                        voice.cancelHold()
                    }
                )
                .frame(minHeight: 24, maxHeight: 72)

                voiceButton

                Group {
                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 2)
                    } else {
                        Button(action: submitPrimary) {
                            Text("Go")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.accentColor.opacity(canGo ? 1 : 0.45))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canGo)
                        .padding(.top, 0)
                        .help("Return to go · Shift+Return for a new line")
                    }
                }
            }

            if voice.isListening {
                listeningBanner
            }

            HStack(spacing: 8) {
                projectChip
                toolMenu
                modelMenu
                Spacer(minLength: 0)
                Button(action: pickAttachments) {
                    ChipLabel(systemIcon: "paperclip", title: attachments.isEmpty ? "Attach" : "\(attachments.count)")
                }
                .buttonStyle(.plain)
                .help("Attach files — ⌘V pastes files from the clipboard")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var canGo: Bool {
        if showProjectPicker { return false }
        if isLaunching { return false }
        let hasPrompt = !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSession = selectedSessionID != nil
        return hasPrompt || hasSession
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
                        Image(systemName: attachment.isImage ? "photo" : "doc")
                            .font(.caption)
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
        Group {
            if sessions.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("Active Windows")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
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
                                launcher.focus(session)
                                onDismiss()
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
            Image(systemName: "bolt.horizontal.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 14))

            Text("fastq")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if let session = sessions.sessions.first(where: { $0.id == selectedSessionID }) {
                FooterAction(title: "Open Window", key: "↩") {
                    launcher.focus(session)
                    onDismiss()
                }
                FooterAction(title: "Quit", key: "⌫") {
                    launcher.quit(session)
                }
            } else {
                FooterAction(title: "Go", key: "↩", action: submitPrimary)
            }

            Divider().frame(height: 14)

            FooterAction(title: "Settings", key: "⌘,") {
                onOpenSettings()
            }
            FooterAction(title: "Actions", key: "⌘K") {
                // Reserved for an action menu in a later pass.
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.18))
    }

    // MARK: - Actions

    private func submitPrimary() {
        if showProjectPicker { return }
        if let session = sessions.sessions.first(where: { $0.id == selectedSessionID }),
           prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcher.focus(session)
            onDismiss()
            return
        }
        Task { await launchAgent() }
    }

    private func bootstrapSelection() {
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

    private func focusPromptSoon() {
        promptFocused = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .fastqFocusLauncherPrompt, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.promptFocused = true
            NotificationCenter.default.post(name: .fastqFocusLauncherPrompt, object: nil)
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
            let session = try await launcher.launch(
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
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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

        // Arrow keys cycle active agent tabs; ⌘V attaches files.
        // Esc is owned by LauncherPanelController.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !LauncherKeyRouter.shared.isProjectPickerOpen else { return event }

            // ↑ / ↓ cycle Fastq Terminal tabs + launcher session selection —
            // but not while the @-mention popup is open (PromptEditor owns those).
            if event.keyCode == 125 || event.keyCode == 126 {
                if LauncherKeyRouter.shared.isMentionPopupOpen { return event }
                let delta = event.keyCode == 125 ? 1 : -1
                DispatchQueue.main.async {
                    cycleActiveSessions(by: delta)
                }
                return nil
            }

            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            let pb = NSPasteboard.general
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ]) as? [URL], !urls.isEmpty {
                DispatchQueue.main.async {
                    LauncherKeyRouter.shared.attachFiles?(urls)
                }
                return nil
            }
            return event
        }
    }

    private func cycleActiveSessions(by delta: Int) {
        let list = sessions.sessions
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex(where: { $0.id == selectedSessionID }) ?? 0
        let count = list.count
        let nextIndex = ((currentIndex + delta) % count + count) % count
        let next = list[nextIndex]
        selectedSessionID = next.id
        if next.hostedInFastqTerminal {
            launcher.selectTerminalTab(next.id)
        }
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
        focusPromptSoon()
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
        HStack(spacing: 6) {
            if let brand {
                AgentBrandIcon(kind: brand, size: 11)
            } else if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isActive ? 180 : 0))
                .opacity(0.7)
        }
        .foregroundStyle(.primary.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(isActive ? 0.14 : 0.07), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(isActive ? 0.22 : 0), lineWidth: 1)
        )
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: isActive)
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
