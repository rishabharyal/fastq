import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BoardView: View {
    @ObservedObject var auth: FastplayAuthStore
    @ObservedObject private var folders = ProjectFolderStore.shared
    @StateObject private var store = BoardStore()
    @State private var detailTask: FastplayTask?
    @State private var showComposer = false
    @State private var composerColumnID: String?
    @State private var draftTaskColumnID: String?

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
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.isLoading && store.board == nil {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedProject == nil {
                ContentUnavailableView(
                    "No project",
                    systemImage: "folder",
                    description: Text("Create or select a project in this workspace.")
                )
            } else {
                kanban
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Workspace", selection: Binding(
                get: { store.selectedWorkspaceID ?? "" },
                set: { id in Task { await store.selectWorkspace(id) } }
            )) {
                ForEach(store.workspaces) { ws in
                    Text(ws.name).tag(ws.id)
                }
            }
            .frame(maxWidth: 220)
            .disabled(store.workspaces.isEmpty)

            Picker("Project", selection: Binding(
                get: { store.selectedProjectID ?? "" },
                set: { id in Task { await store.selectProject(id) } }
            )) {
                ForEach(store.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
            .frame(maxWidth: 220)
            .disabled(store.projects.isEmpty)

            Button {
                store.newProjectName = ""
                store.showNewProjectSheet = true
            } label: {
                Label("New Project", systemImage: "folder.badge.plus")
            }
            .disabled(store.selectedWorkspace == nil)

            if let project = store.selectedProject {
                folderLinkControl(for: project)
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

    private func folderLinkControl(for project: FastplayProject) -> some View {
        let linked = folders.path(for: project.id)
        let label = linked.map { URL(fileURLWithPath: $0).path } ?? "No folder linked"
        return HStack(spacing: 8) {
            Image(systemName: linked == nil ? "folder.badge.questionmark" : "folder.fill")
                .foregroundStyle(linked == nil ? Color.orange : Color.secondary)
            Text(linked.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No folder linked")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .help(label)
            if linked != nil {
                Button("Change…") { pickFolder(for: project.id) }
                    .controlSize(.small)
                Button("Clear", role: .destructive) { folders.clear(for: project.id) }
                    .controlSize(.small)
            } else {
                Button("Link folder…") { pickFolder(for: project.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
