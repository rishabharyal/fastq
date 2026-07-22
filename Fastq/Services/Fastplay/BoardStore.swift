import Foundation
import Combine

/// Loads Fastplay workspaces → projects → kanban board for the Board window.
@MainActor
final class BoardStore: ObservableObject {
    @Published var workspaces: [FastplayWorkspace] = []
    @Published var projects: [FastplayProject] = []
    @Published var board: FastplayBoard?
    @Published var selectedWorkspaceID: String?
    @Published var selectedProjectID: String?
    @Published var selectedColumnID: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var newTaskTitle = ""
    @Published var showNewProjectSheet = false
    @Published var newProjectName = ""
    /// Workspace labels, loaded lazily for the composer / detail views.
    @Published var workspaceLabels: [FastplayLabel] = []

    var selectedWorkspace: FastplayWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedProject: FastplayProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedColumn: FastplayColumn? {
        board?.columns.first { $0.id == selectedColumnID }
    }

    /// Flat task list for the launcher Projects mode (Todo-first column order).
    var flatTasks: [(column: FastplayColumn, task: FastplayTask)] {
        guard let board else { return [] }
        return board.columns
            .sorted { $0.position < $1.position }
            .flatMap { column in column.tasks.map { (column, $0) } }
    }

    private let defaultsKey = "fastq.fastplay.board.selection.v1"

    init() {
        if let data = UserDefaults.standard.dictionary(forKey: defaultsKey) {
            selectedWorkspaceID = data["workspace"] as? String
            selectedProjectID = data["project"] as? String
            selectedColumnID = data["column"] as? String
        }
    }

    func bootstrap() async {
        guard FastplayAuthStore.shared.isLoggedIn else {
            errorMessage = "Sign in to use Boards."
            return
        }
        await refreshWorkspaces()
    }

    func refreshWorkspaces() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let list = try await FastplayAPIClient.shared.workspaces()
            workspaces = list
            if selectedWorkspaceID == nil || !list.contains(where: { $0.id == selectedWorkspaceID }) {
                selectedWorkspaceID = list.first?.id
            }
            persistSelection()
            await refreshProjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectWorkspace(_ id: String) async {
        selectedWorkspaceID = id
        selectedProjectID = nil
        board = nil
        persistSelection()
        await refreshProjects()
    }

    func refreshProjects() async {
        guard let ws = selectedWorkspace else {
            projects = []
            board = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let list = try await FastplayAPIClient.shared.projects(workspace: ws.routeKey)
            projects = list
            if selectedProjectID == nil || !list.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = list.first?.id
            }
            persistSelection()
            await refreshBoard()
        } catch {
            errorMessage = error.localizedDescription
            projects = []
            board = nil
        }
    }

    func selectProject(_ id: String) async {
        selectedProjectID = id
        persistSelection()
        await refreshBoard()
    }

    func refreshBoard() async {
        guard let ws = selectedWorkspace, let project = selectedProject else {
            board = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await FastplayAPIClient.shared.board(workspace: ws.routeKey, project: project.routeKey)
            board = loaded
            syncSelectedColumn(with: loaded)
            persistSelection()
        } catch {
            errorMessage = error.localizedDescription
            board = nil
        }
    }

    func selectColumn(_ id: String) {
        selectedColumnID = id
        persistSelection()
    }

    private func syncSelectedColumn(with board: FastplayBoard) {
        let sorted = board.columns.sorted { $0.position < $1.position }
        if selectedColumnID == nil || !sorted.contains(where: { $0.id == selectedColumnID }) {
            selectedColumnID = sorted.first?.id
        }
    }

    func createProject(name: String) async {
        guard let ws = selectedWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let project = try await FastplayAPIClient.shared.createProject(workspace: ws.routeKey, name: trimmed)
            projects.insert(project, at: 0)
            selectedProjectID = project.id
            newProjectName = ""
            showNewProjectSheet = false
            persistSelection()
            await refreshBoard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createTask(title: String, columnID: String?) async -> FastplayTask? {
        guard let ws = selectedWorkspace, let project = selectedProject else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let task = try await FastplayAPIClient.shared.createTask(
                workspace: ws.routeKey,
                project: project.routeKey,
                title: trimmed,
                columnID: columnID
            )
            newTaskTitle = ""
            await refreshBoard()
            return task
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Launcher Projects mode: create a task, then upload any file attachments.
    @discardableResult
    func createTaskFromLauncher(
        title: String,
        description: String? = nil,
        columnID: String?,
        assigneeIDs: [String] = [],
        attachmentURLs: [URL]
    ) async throws -> FastplayTask {
        var draft = FastplayTaskDraft()
        draft.title = title
        draft.description = description ?? ""
        draft.columnID = columnID ?? selectedColumnID
        draft.assigneeIDs = assigneeIDs
        draft.attachmentURLs = attachmentURLs
        return try await createTask(draft: draft)
    }

    /// Full-fidelity creation used by the composer: one POST with every field
    /// the API accepts, then sequential attachment uploads.
    @discardableResult
    func createTask(
        draft: FastplayTaskDraft,
        onUploadProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> FastplayTask {
        guard let ws = selectedWorkspace, let project = selectedProject else {
            throw FastplayAPIError.message("Pick a workspace and project first.")
        }
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FastplayAPIError.message("Task title can’t be empty.")
        }
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = try await FastplayAPIClient.shared.createTask(
            workspace: ws.routeKey,
            project: project.routeKey,
            title: trimmed,
            description: description.isEmpty ? nil : description,
            columnID: draft.columnID ?? selectedColumnID,
            priority: draft.priority,
            startDate: draft.startDate.map(FastplayDates.apiDay),
            dueDate: draft.dueDate.map(FastplayDates.apiDay),
            labelIDs: draft.labelIDs.isEmpty ? nil : draft.labelIDs,
            assigneeIDs: draft.assigneeIDs.isEmpty ? nil : draft.assigneeIDs
        )
        for (index, url) in draft.attachmentURLs.enumerated() {
            onUploadProgress?(index + 1, draft.attachmentURLs.count)
            _ = try await FastplayAPIClient.shared.uploadTaskAttachment(
                workspace: ws.routeKey,
                project: project.routeKey,
                taskID: task.id,
                fileURL: url
            )
        }
        await refreshBoard()
        return task
    }

    func refreshLabels() async {
        guard let ws = selectedWorkspace else {
            workspaceLabels = []
            return
        }
        do {
            workspaceLabels = try await FastplayAPIClient.shared.labels(workspace: ws.routeKey)
        } catch {
            // Labels are decorative here — keep whatever we had.
        }
    }

    @discardableResult
    func createLabel(name: String, color: String) async -> FastplayLabel? {
        guard let ws = selectedWorkspace else { return nil }
        do {
            let label = try await FastplayAPIClient.shared.createLabel(workspace: ws.routeKey, name: name, color: color)
            workspaceLabels.append(label)
            return label
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameTask(_ task: FastplayTask, title: String) async {
        guard let ws = selectedWorkspace, let project = selectedProject else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await FastplayAPIClient.shared.updateTask(
                workspace: ws.routeKey,
                project: project.routeKey,
                taskID: task.id,
                title: trimmed
            )
            await refreshBoard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTask(_ task: FastplayTask) async {
        guard let ws = selectedWorkspace, let project = selectedProject else { return }
        do {
            try await FastplayAPIClient.shared.deleteTask(
                workspace: ws.routeKey,
                project: project.routeKey,
                taskID: task.id
            )
            await refreshBoard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveTask(_ task: FastplayTask, to columnID: String) async {
        guard let ws = selectedWorkspace, let project = selectedProject else { return }
        guard task.boardColumnID != columnID else { return }
        do {
            _ = try await FastplayAPIClient.shared.moveTask(
                workspace: ws.routeKey,
                project: project.routeKey,
                taskID: task.id,
                columnID: columnID
            )
            await refreshBoard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistSelection() {
        var dict: [String: String] = [:]
        if let selectedWorkspaceID { dict["workspace"] = selectedWorkspaceID }
        if let selectedProjectID { dict["project"] = selectedProjectID }
        if let selectedColumnID { dict["column"] = selectedColumnID }
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }
}
