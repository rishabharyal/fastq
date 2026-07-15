import SwiftUI
import AppKit

struct BoardView: View {
    @ObservedObject var auth: FastplayAuthStore
    @StateObject private var store = BoardStore()
    @State private var editingTask: FastplayTask?
    @State private var editTitle = ""
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
        .sheet(item: $editingTask) { task in
            editTaskSheet(task)
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

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            }

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

    private var kanban: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(store.board?.columns ?? []) { column in
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
                                await store.createTask(title: title, columnID: column.id)
                                draftTaskColumnID = nil
                            }
                        },
                        onEdit: { task in
                            editingTask = task
                            editTitle = task.title
                        },
                        onDelete: { task in
                            Task { await store.deleteTask(task) }
                        },
                        onMove: { task, targetColumnID in
                            Task { await store.moveTask(task, to: targetColumnID) }
                        },
                        allColumns: store.board?.columns ?? []
                    )
                }
            }
            .padding(16)
        }
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

    private func editTaskSheet(_ task: FastplayTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit task")
                .font(.headline)
            TextField("Title", text: $editTitle)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { editingTask = nil }
                Button("Save") {
                    Task {
                        await store.renameTask(task, title: editTitle)
                        editingTask = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
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
    var onEdit: (FastplayTask) -> Void
    var onDelete: (FastplayTask) -> Void
    var onMove: (FastplayTask, String) -> Void
    var allColumns: [FastplayColumn]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(column.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(column.tasks.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            TextField("Add task…", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSubmitDraft)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(column.tasks) { task in
                        taskCard(task)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func taskCard(_ task: FastplayTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let priority = task.priority, !priority.isEmpty {
                Text(priority.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .contextMenu {
            Button("Edit") { onEdit(task) }
            Menu("Move to") {
                ForEach(allColumns) { col in
                    Button(col.name) { onMove(task, col.id) }
                        .disabled(col.id == column.id)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete(task) }
        }
        .onTapGesture(count: 2) { onEdit(task) }
    }
}
