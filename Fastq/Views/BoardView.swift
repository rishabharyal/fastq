import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What the main area of the board window is showing: the kanban, or one of the
/// open agent runs.
enum BoardTab: Hashable {
    case board
    case run(UUID)
}

struct BoardView: View {
    @ObservedObject var auth: FastplayAuthStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject private var folders = ProjectFolderStore.shared
    @StateObject private var store = BoardStore()
    @State private var detailTask: FastplayTask?
    @State private var showComposer = false
    @State private var composerColumnID: String?
    @State private var draftTaskColumnID: String?

    /// Sidebar collapse state, toggled with ⌘S and remembered across launches.
    @AppStorage("fastq.board.sidebarVisible") private var sidebarVisible = true
    @AppStorage("fastq.board.sidebarWidth") private var storedSidebarWidth: Double = 240

    private var sidebarWidth: CGFloat { CGFloat(storedSidebarWidth) }
    /// Agent runs the user has opened as tabs, in tab order.
    @State private var openRunIDs: [UUID] = []
    @State private var selectedTab: BoardTab = .board
    /// Session IDs already seen, so newly launched agents auto-open exactly once.
    @State private var knownSessionIDs: Set<UUID> = []

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                signedOut
            } else {
                signedIn
            }
        }
        .frame(minWidth: 920, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if auth.isLoggedIn {
                await store.bootstrap()
            }
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if loggedIn {
                Task { await store.bootstrap() }
            } else {
                store.workspaces = []
                store.projects = []
                store.board = nil
            }
        }
        .sheet(isPresented: $store.showNewProjectSheet) {
            newProjectSheet
        }
        .sheet(isPresented: $showComposer) {
            TaskComposerView(
                store: store,
                initialColumnID: composerColumnID,
                onCreated: { _ in showComposer = false },
                onCancel: { showComposer = false }
            )
        }
        .sheet(item: $detailTask) { task in
            TaskDetailView(
                task: task,
                boardStore: store,
                onClose: { detailTask = nil },
                onStartAgent: { task in
                    startAgent(task)
                    detailTask = nil
                }
            )
        }
        .alert("Board", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var signedOut: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Sign in to use Boards")
                .font(.title2.weight(.semibold))
            Text("Open Settings → Account to log in with your Fastplay account.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedIn: some View {
        HStack(spacing: 0) {
            // Always mounted and animated to zero width: a conditional branch
            // pops instead of sliding, and remounting resets scroll position.
            sidebar
                .frame(width: sidebarVisible ? sidebarWidth : 0)
                .opacity(sidebarVisible ? 1 : 0)
                .clipped()
                .allowsHitTesting(sidebarVisible)
            if sidebarVisible {
                ResizeHandle(
                    width: $storedSidebarWidth,
                    range: 190...420,
                    accessibilityName: "sidebar"
                )
            }
            VStack(spacing: 0) {
                boardHeader
                Divider()
                if !openRunIDs.isEmpty {
                    tabStrip
                    Divider()
                }
                mainContent
            }
            .frame(maxWidth: .infinity)
        }
        .background(sidebarShortcut)
        .onReceive(sessions.$sessions) { list in
            adoptNewSessions(list)
        }
    }

    /// ⌘S toggles the sidebar. Hidden button so the shortcut is scoped to this window.
    private var sidebarShortcut: some View {
        Button("Toggle Sidebar") {
            withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch selectedTab {
        case .board:
            if store.isLoading && store.board == nil {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedProject == nil {
                ContentUnavailableView(
                    "No project",
                    systemImage: "folder",
                    description: Text("Create or select a project in the sidebar.")
                )
            } else {
                kanban
            }
        case .run(let id):
            AgentRunView(
                sessionID: id,
                sessions: sessions,
                boardStore: store,
                projectPath: runProjectPath(for: id),
                onClose: { closeRun(id) },
                onOpenTaskDetail: { task in detailTask = task }
            )
        }
    }

    /// The local folder the run's project is linked to, for the inspector panes.
    private func runProjectPath(for id: UUID) -> String? {
        guard let session = sessions.session(id: id) else { return nil }
        if let projectID = session.taskLink?.projectID, let path = folders.path(for: projectID) {
            return path
        }
        return session.projectPath.isEmpty ? nil : session.projectPath
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabChip(
                    title: "Board",
                    systemImage: "rectangle.split.3x1",
                    isSelected: selectedTab == .board,
                    onSelect: { selectedTab = .board },
                    onClose: nil
                )
                ForEach(openRunIDs, id: \.self) { id in
                    tabChip(
                        title: runTitle(for: id),
                        systemImage: "sparkles",
                        isSelected: selectedTab == .run(id),
                        onSelect: { selectedTab = .run(id) },
                        onClose: { closeRun(id) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(FQTheme.background)
    }

    private func tabChip(
        title: String,
        systemImage: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onClose: (() -> Void)?
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
            }
        }
        .foregroundStyle(isSelected ? FQTheme.textPrimary : FQTheme.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                .fill(isSelected ? FQTheme.surface : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                .strokeBorder(isSelected ? FQTheme.border : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityLabel("\(title) tab\(isSelected ? ", selected" : "")")
    }

    private func runTitle(for id: UUID) -> String {
        guard let session = sessions.session(id: id) else { return "Agent" }
        if let title = session.taskLink?.taskTitle, !title.isEmpty { return title }
        let preview = session.promptPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? session.tool.displayName : String(preview.prefix(28))
    }

    private func openRun(_ id: UUID) {
        if !openRunIDs.contains(id) { openRunIDs.append(id) }
        selectedTab = .run(id)
    }

    private func closeRun(_ id: UUID) {
        openRunIDs.removeAll { $0 == id }
        if selectedTab == .run(id) {
            selectedTab = openRunIDs.last.map { BoardTab.run($0) } ?? .board
        }
    }

    /// Auto-opens a tab for an agent launched while the board is open, so starting
    /// a run from a task lands the user straight in it.
    private func adoptNewSessions(_ list: [AgentSession]) {
        let current = Set(list.map(\.id))
        defer { knownSessionIDs = current }
        guard !knownSessionIDs.isEmpty else { return }
        let fresh = list.filter { !knownSessionIDs.contains($0.id) }
        for session in fresh where belongsToSelectedProject(session) {
            openRun(session.id)
        }
        // Drop tabs whose session has gone away entirely.
        openRunIDs.removeAll { !current.contains($0) }
        if case .run(let id) = selectedTab, !current.contains(id) {
            selectedTab = openRunIDs.last.map { BoardTab.run($0) } ?? .board
        }
    }

    private func belongsToSelectedProject(_ session: AgentSession) -> Bool {
        if let projectID = store.selectedProjectID {
            if session.taskLink?.projectID == projectID { return true }
            if let path = folders.path(for: projectID), path == session.projectPath { return true }
        }
        return false
    }

    private func agentSessions(for project: FastplayProject) -> [AgentSession] {
        sessions.sessions(forProjectID: project.id, projectPath: folders.path(for: project.id))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceSwitcher
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            HStack(spacing: 6) {
                Text("Projects")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(FQTheme.textSecondary)
                Spacer()
                FQIconButton(systemImage: "plus", size: 20, iconSize: 10, help: "New project…") {
                    store.newProjectName = ""
                    store.showNewProjectSheet = true
                }
                .disabled(store.selectedWorkspace == nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if store.projects.isEmpty {
                Text("No projects in this workspace yet.")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.projects) { project in
                            ProjectSidebarRow(
                                project: project,
                                isSelected: project.id == store.selectedProjectID,
                                folderPath: folders.path(for: project.id),
                                onSelect: { Task { await store.selectProject(project.id) } },
                                onPickFolder: { pickFolder(for: project.id) },
                                onRevealFolder: { revealFolder(for: project.id) },
                                onClearFolder: { folders.clear(for: project.id) }
                            )
                            ForEach(agentSessions(for: project)) { session in
                                AgentSidebarRow(
                                    session: session,
                                    isSelected: selectedTab == .run(session.id),
                                    onSelect: { openRun(session.id) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(FQTheme.background)
    }

    private var workspaceSwitcher: some View {
        Menu {
            ForEach(store.workspaces) { ws in
                Button {
                    Task { await store.selectWorkspace(ws.id) }
                } label: {
                    if ws.id == store.selectedWorkspaceID {
                        Label(ws.name, systemImage: "checkmark")
                    } else {
                        Text(ws.name)
                    }
                }
            }
            Divider()
            Button("Refresh workspaces") {
                Task { await store.refreshWorkspaces() }
            }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FQTheme.controlPrimary)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text(workspaceInitial)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(FQTheme.onControlPrimary)
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.selectedWorkspace?.name ?? "No workspace")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(FQTheme.textPrimary)
                        .lineLimit(1)
                    Text("Workspace")
                        .font(.system(size: 10))
                        .foregroundStyle(FQTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FQTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            // An explicit width keeps `.fixedSize()` happy: a borderlessButton
            // menu whose label is flexible collapses to just the indicator.
            .frame(width: sidebarWidth - 20, alignment: .leading)
            .background(FQTheme.surface, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                    .strokeBorder(FQTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.workspaces.isEmpty)
        .accessibilityLabel("Workspace: \(store.selectedWorkspace?.name ?? "none")")
    }

    private var workspaceInitial: String {
        let name = store.selectedWorkspace?.name ?? "?"
        return String(name.first.map(String.init) ?? "?").uppercased()
    }

    // MARK: - Board header

    private var boardHeader: some View {
        HStack(spacing: 10) {
            FQIconButton(
                systemImage: "sidebar.leading",
                size: 24,
                iconSize: 12,
                help: sidebarVisible ? "Hide sidebar (⌘S)" : "Show sidebar (⌘S)"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() }
            }

            Text(store.selectedProject?.name ?? "Board")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FQTheme.textPrimary)
                .lineLimit(1)

            if let project = store.selectedProject, let path = folders.path(for: project.id) {
                FQStatusPill(text: URL(fileURLWithPath: path).lastPathComponent, hue: .gray)
                    .help(path)
            }

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            }

            Button {
                composerColumnID = nil
                showComposer = true
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.selectedProject == nil)
            .help("Create a task with description, priority, dates, labels, assignees, and attachments")

            Button {
                Task { await store.refreshBoard() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh board")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func revealFolder(for projectID: String) {
        guard let path = folders.path(for: projectID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func pickFolder(for projectID: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Link Folder"
        panel.message = "Choose the local folder for this project. Agents will run here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folders.setPath(url.path, for: projectID)
    }

    private var kanban: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(sortedColumns) { column in
                    BoardColumnView(
                        column: column,
                        draftTitle: Binding(
                            get: {
                                draftTaskColumnID == column.id ? store.newTaskTitle : ""
                            },
                            set: { value in
                                draftTaskColumnID = column.id
                                store.newTaskTitle = value
                            }
                        ),
                        onSubmitDraft: {
                            let title = store.newTaskTitle
                            Task {
                                _ = await store.createTask(title: title, columnID: column.id)
                                draftTaskColumnID = nil
                            }
                        },
                        onCompose: {
                            composerColumnID = column.id
                            showComposer = true
                        },
                        onOpen: { task in
                            detailTask = task
                        },
                        onDelete: { task in
                            Task { await store.deleteTask(task) }
                        },
                        onMove: { task, targetColumnID in
                            Task { await store.moveTask(task, to: targetColumnID) }
                        },
                        onDropTaskID: { taskID in
                            guard let task = findTask(taskID) else { return }
                            Task { await store.moveTask(task, to: column.id) }
                        },
                        onStartAgent: { task in
                            startAgent(task, columnName: column.name)
                        },
                        allColumns: sortedColumns
                    )
                }
            }
            .padding(16)
        }
    }

    private var sortedColumns: [FastplayColumn] {
        (store.board?.columns ?? []).sorted { $0.position < $1.position }
    }

    private func findTask(_ id: String) -> FastplayTask? {
        for column in store.board?.columns ?? [] {
            if let task = column.tasks.first(where: { $0.id == id }) {
                return task
            }
        }
        return nil
    }

    private func startAgent(_ task: FastplayTask, columnName: String? = nil) {
        let column = columnName
            ?? store.board?.columns.first { $0.id == task.boardColumnID }?.name
        StartAgentForTask.post(
            task: task,
            columnName: column ?? task.resolvedColumnName ?? "Task",
            workspaceID: store.selectedWorkspaceID,
            projectID: store.selectedProjectID,
            autoLaunch: true
        )
    }

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New project")
                .font(.headline)
            TextField("Project name", text: $store.newProjectName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await store.createProject(name: store.newProjectName) }
                }
            HStack {
                Spacer()
                Button("Cancel") { store.showNewProjectSheet = false }
                Button("Create") {
                    Task { await store.createProject(name: store.newProjectName) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// One project in the sidebar: name, linked-folder subtitle, and a gear menu
/// for per-project configuration.
private struct ProjectSidebarRow: View {
    let project: FastplayProject
    let isSelected: Bool
    let folderPath: String?
    var onSelect: () -> Void
    var onPickFolder: () -> Void
    var onRevealFolder: () -> Void
    var onClearFolder: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folderPath == nil ? "folder.badge.questionmark" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(folderPath == nil ? FQTheme.warning : FQTheme.textSecondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(FQTheme.textPrimary)
                    .lineLimit(1)
                Text(folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No folder linked")
                    .font(.system(size: 10))
                    .foregroundStyle(FQTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isHovering || isSelected {
                settingsMenu
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                .fill(isSelected ? FQTheme.surfaceSecondary : (isHovering ? FQTheme.surfaceSecondary.opacity(0.6) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(folderPath ?? "No folder linked")
        .accessibilityLabel("Project \(project.name)\(isSelected ? ", selected" : "")")
    }

    private var settingsMenu: some View {
        Menu {
            if folderPath == nil {
                Button("Link folder…", action: onPickFolder)
            } else {
                Button("Change folder…", action: onPickFolder)
                Button("Reveal in Finder", action: onRevealFolder)
                Divider()
                Button("Clear folder", role: .destructive, action: onClearFolder)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FQTheme.textSecondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project settings")
        .accessibilityLabel("Settings for \(project.name)")
    }
}

/// A running (or finished) agent listed under its project in the sidebar.
private struct AgentSidebarRow: View {
    let session: AgentSession
    let isSelected: Bool
    var onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? FQTheme.textPrimary : FQTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.status == .running {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(FQTheme.accent)
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                .fill(isSelected ? FQTheme.surfaceSecondary : (isHovering ? FQTheme.surfaceSecondary.opacity(0.5) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel("Agent run \(title), \(session.status == .running ? "running" : "stopped")")
    }

    private var title: String {
        if let taskTitle = session.taskLink?.taskTitle, !taskTitle.isEmpty { return taskTitle }
        let preview = session.promptPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? session.tool.displayName : preview
    }

    private var statusColor: Color {
        switch session.status {
        case .running: return FQTheme.success
        case .launching: return FQTheme.warning
        case .exited: return FQTheme.textTertiary
        }
    }
}

private struct BoardColumnView: View {
    let column: FastplayColumn
    @Binding var draftTitle: String
    var onSubmitDraft: () -> Void
    var onCompose: () -> Void
    var onOpen: (FastplayTask) -> Void
    var onDelete: (FastplayTask) -> Void
    var onMove: (FastplayTask, String) -> Void
    var onDropTaskID: (String) -> Void
    var onStartAgent: (FastplayTask) -> Void
    var allColumns: [FastplayColumn]

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 4)

            if column.tasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(column.tasks) { task in
                            BoardTaskCard(
                                task: task,
                                columnID: column.id,
                                allColumns: allColumns,
                                onOpen: { onOpen(task) },
                                onDelete: { onDelete(task) },
                                onMove: { target in onMove(task, target) },
                                onStartAgent: { onStartAgent(task) }
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(10)
        .frame(width: 290, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FQTheme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? FQTheme.focusRing : Color.clear,
                    lineWidth: 2
                )
        )
        .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String else { return }
                DispatchQueue.main.async {
                    onDropTaskID(id)
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(boardColumnTint(column))
                .frame(width: 8, height: 8)
            Text(column.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(FQTheme.textPrimary)
            FQIconButton(systemImage: "plus", size: 20, iconSize: 10, help: "New task in \(column.name)…") {
                onCompose()
            }
            Spacer()
            Text("\(column.tasks.count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FQTheme.textSecondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)
            Text("Nothing in \(column.name.lowercased())")
                .font(FQTheme.fontBodyMedium)
                .foregroundStyle(FQTheme.textPrimary)
            Text("Cards you move here will appear in this column.")
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BoardTaskCard: View {
    let task: FastplayTask
    let columnID: String
    let allColumns: [FastplayColumn]
    var onOpen: () -> Void
    var onDelete: () -> Void
    var onMove: (String) -> Void
    var onStartAgent: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                FQStatusPill(text: task.shortCode, hue: .gray)
                if let p = task.priorityValue {
                    PriorityBadge(priority: p)
                }
                Spacer()
                cardMenu
            }

            Text(task.title)
                .font(.system(size: 13.5, weight: .semibold))
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? FQTheme.textSecondary : FQTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            if let description = plainDescription {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(FQTheme.textSecondary)
                    .lineLimit(2)
                    .lineSpacing(1.5)
            }

            if let labels = task.labels, !labels.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(labels.prefix(4)) { label in
                        LabelChipView(label: label, compact: true)
                    }
                    if labels.count > 4 {
                        Text("+\(labels.count - 4)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(FQTheme.textSecondary)
                    }
                }
            }

            HStack(spacing: 5) {
                Text(footerLine)
                    .font(.system(size: 11))
                    .foregroundStyle(FQTheme.textSecondary)
                    .lineLimit(1)
                MetaCountBadge(systemImage: "paperclip", count: task.attachmentsCount ?? 0, help: "Attachments")
                MetaCountBadge(systemImage: "text.bubble", count: task.commentsCount ?? 0, help: "Comments")
                MetaCountBadge(systemImage: "checklist", count: task.subtasksCount ?? 0, help: "Subtasks")
                Spacer(minLength: 0)
                if let assignees = task.assignees, !assignees.isEmpty {
                    AvatarStack(users: assignees, size: 17)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FQTheme.radiusMedium, style: .continuous)
                .fill(FQTheme.surface)
                .shadow(color: .black.opacity(isHovering ? 0.10 : 0.05), radius: isHovering ? 6 : 3, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FQTheme.radiusMedium, style: .continuous)
                .strokeBorder(isHovering ? FQTheme.borderEmphasized : FQTheme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .onDrag { NSItemProvider(object: task.id as NSString) }
        .contextMenu { menuItems }
        .accessibilityLabel("Task: \(task.title)")
    }

    private var cardMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FQTheme.textSecondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Task actions")
        .accessibilityLabel("Task actions")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open") { onOpen() }
        Button("Start agent") { onStartAgent() }
        Menu("Move to") {
            ForEach(allColumns) { col in
                Button(col.name) { onMove(col.id) }
                    .disabled(col.id == columnID)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }

    /// Description with mention markup flattened for the excerpt.
    private var plainDescription: String? {
        guard let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        return String(MentionMarkup.styled(description).characters)
    }

    private var footerLine: String {
        var parts: [String] = []
        if let added = FastplayDates.relative(task.createdAt) {
            parts.append("Added \(added)")
        }
        if let due = FastplayDates.parse(task.dueDate) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            let overdue = !task.isCompleted && due < Calendar.current.startOfDay(for: Date())
            parts.append("\(overdue ? "Overdue" : "Due") \(formatter.string(from: due))")
        }
        return parts.joined(separator: " · ")
    }
}
