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
        .onAppear {
            bootstrapSelection()
            focusPromptSoon()
            installKeyMonitors()
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
        .alert("Couldn’t launch agent", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)

                // Single-line: Return launches. (Vertical TextField eats Return as newline.)
                TextField("Ask an agent about this project…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .medium))
                    .focused($promptFocused)
                    .disabled(showProjectPicker)
                    .onSubmit(submitPrimary)

                if isLaunching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Launch")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    KeyCap(symbol: "↩")
                }
            }

            HStack(spacing: 8) {
                projectChip
                toolMenu
                modelMenu
                Spacer(minLength: 0)
                Button(action: pickAttachments) {
                    ChipLabel(icon: "paperclip", title: attachments.isEmpty ? "Attach" : "\(attachments.count)")
                }
                .buttonStyle(.plain)
                .help("Attach files — ⌘V pastes files from the clipboard")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var projectChip: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                showProjectPicker.toggle()
                LauncherKeyRouter.shared.isProjectPickerOpen = showProjectPicker
            }
        } label: {
            ChipLabel(
                icon: "folder.fill",
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
            .padding(.top, 78)
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
                    Label(tool.displayName, systemImage: tool.kind.systemImage)
                }
            }
        } label: {
            ChipLabel(icon: selectedTool?.kind.systemImage ?? "hammer", title: selectedTool?.displayName ?? "Tool")
        }
        .menuStyle(.borderlessButton)
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
            ChipLabel(icon: "cpu", title: selectedModel.displayName)
        }
        .menuStyle(.borderlessButton)
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
                FooterAction(title: "Launch Agent", key: "↩", action: submitPrimary)
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
        DispatchQueue.main.async {
            promptFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            promptFocused = true
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
                attachments: attachments
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
        LauncherKeyRouter.shared.isProjectPickerOpen = showProjectPicker
        LauncherKeyRouter.shared.closePicker = {
            pickerBinding.wrappedValue = false
        }
        LauncherKeyRouter.shared.attachFiles = { [attachments = $attachments] urls in
            var current = attachments.wrappedValue
            for url in urls where !current.contains(where: { $0.path == url.path }) {
                current.append(PromptAttachment(url: url))
            }
            attachments.wrappedValue = current
        }

        // Only handle ⌘V file paste here. Esc is owned by LauncherPanelController
        // so it always hides the panel even when the TextField has focus.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !LauncherKeyRouter.shared.isProjectPickerOpen else { return event }
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

    private func removeKeyMonitors() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
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
                Image(systemName: session.tool.systemImage)
                    .foregroundStyle(.primary)
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
    let icon: String
    let title: String
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
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
