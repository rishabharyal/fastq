import Foundation
import Combine

/// State + actions for one task's detail view: full task, comments,
/// attachments, subtasks, watchers, and activity.
@MainActor
final class TaskDetailStore: ObservableObject {
    struct Context {
        var workspace: String        // route key (slug or id)
        var workspaceID: String?     // uuid, for user search
        var project: String          // route key
        var columns: [FastplayColumn]
    }

    @Published var task: FastplayTask
    @Published var comments: [FastplayComment] = []
    @Published var attachments: [FastplayAttachment] = []
    @Published var subtasks: [FastplayTask] = []
    @Published var watchers: [FastplayWatcher] = []
    @Published var activities: [FastplayActivity] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var busyAttachmentIDs: Set<String> = []

    let context: Context
    /// Called after any mutation so the owning board can refresh.
    var onChanged: (() -> Void)?

    private let client = FastplayAPIClient.shared

    init(task: FastplayTask, context: Context) {
        self.task = task
        self.context = context
    }

    var isWatching: Bool {
        guard let me = FastplayAuthStore.shared.user?.id else { return false }
        return watchers.contains { $0.id == me }
    }

    var column: FastplayColumn? {
        context.columns.first { $0.id == task.boardColumnID }
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let fresh = fetchTask()
        async let comments = fetch { try await self.client.comments(workspace: self.ws, project: self.proj, taskID: self.id) }
        async let attachments = fetch { try await self.client.taskAttachments(workspace: self.ws, project: self.proj, taskID: self.id) }
        async let subtasks = fetch { try await self.client.subtasks(workspace: self.ws, project: self.proj, taskID: self.id) }
        async let watchers = fetch { try await self.client.watchers(workspace: self.ws, project: self.proj, taskID: self.id) }
        async let activities = fetch { try await self.client.taskActivities(workspace: self.ws, project: self.proj, taskID: self.id) }
        if let fresh = await fresh { task = fresh }
        self.comments = await comments ?? []
        self.attachments = await attachments ?? []
        self.subtasks = await subtasks ?? []
        self.watchers = await watchers ?? []
        self.activities = await activities ?? []
    }

    private func fetchTask() async -> FastplayTask? {
        await fetch { try await self.client.task(workspace: self.ws, project: self.proj, taskID: self.id) }
    }

    private func fetch<T>(_ op: @escaping () async throws -> T) async -> T? {
        do {
            return try await op()
        } catch {
            return nil
        }
    }

    // MARK: - Core fields

    func saveTitle(_ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return }
        await update(title: trimmed)
    }

    func saveDescription(_ text: String) async {
        await update(description: text)
    }

    func setPriority(_ priority: TaskPriority?) async {
        // The DB enum has no "none"; empty string clears via nullable validation.
        await update(priority: priority?.rawValue ?? "")
    }

    func setStatus(_ status: String) async {
        await update(status: status)
    }

    func setStartDate(_ date: Date?) async {
        guard let date else { return }
        await update(startDate: FastplayDates.apiDay(date))
    }

    func setDueDate(_ date: Date?) async {
        guard let date else { return }
        await update(dueDate: FastplayDates.apiDay(date))
    }

    private func update(
        title: String? = nil,
        description: String? = nil,
        priority: String? = nil,
        status: String? = nil,
        startDate: String? = nil,
        dueDate: String? = nil
    ) async {
        do {
            let updated = try await client.updateTask(
                workspace: ws, project: proj, taskID: id,
                title: title, description: description,
                priority: priority, status: status,
                startDate: startDate, dueDate: dueDate
            )
            merge(updated)
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Server responses to update/move omit eager-loaded relations — keep ours.
    private func merge(_ updated: FastplayTask) {
        var next = updated
        if next.assignees == nil { next.assignees = task.assignees }
        if next.labels == nil { next.labels = task.labels }
        if next.reporter == nil { next.reporter = task.reporter }
        if next.column == nil { next.column = task.column }
        task = next
    }

    func move(toColumn columnID: String) async {
        guard columnID != task.boardColumnID else { return }
        do {
            let updated = try await client.moveTask(workspace: ws, project: proj, taskID: id, columnID: columnID)
            merge(updated)
            task.column = context.columns.first { $0.id == columnID }
                .map { FastplayTaskColumnRef(id: $0.id, name: $0.name) }
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTask() async -> Bool {
        do {
            try await client.deleteTask(workspace: ws, project: proj, taskID: id)
            onChanged?()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Labels

    func toggleLabel(_ label: FastplayLabel) async {
        do {
            if task.labels?.contains(where: { $0.id == label.id }) == true {
                try await client.detachLabel(workspace: ws, project: proj, taskID: id, labelID: label.id)
                task.labels?.removeAll { $0.id == label.id }
            } else {
                let all = try await client.attachLabel(workspace: ws, project: proj, taskID: id, labelID: label.id)
                task.labels = all
            }
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Assignees

    func addAssignee(_ user: FastplayUser) async {
        do {
            let all = try await client.addAssignee(workspace: ws, project: proj, taskID: id, userID: user.id)
            task.assignees = all
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAssignee(_ user: FastplayUser) async {
        do {
            try await client.removeAssignee(workspace: ws, project: proj, taskID: id, userID: user.id)
            task.assignees?.removeAll { $0.id == user.id }
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func searchWorkspaceUsers(_ query: String) async -> [FastplayUser] {
        (try? await client.searchUsers(query: query, workspaceID: context.workspaceID)) ?? []
    }

    // MARK: - Comments

    func addComment(_ body: String, parentID: String? = nil) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.addComment(workspace: ws, project: proj, taskID: id, body: trimmed, parentID: parentID)
            comments = (try? await client.comments(workspace: ws, project: proj, taskID: id)) ?? comments
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteComment(_ comment: FastplayComment) async {
        do {
            try await client.deleteComment(workspace: ws, project: proj, taskID: id, commentID: comment.id)
            comments = (try? await client.comments(workspace: ws, project: proj, taskID: id)) ?? comments
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Attachments

    func uploadAttachments(_ urls: [URL]) async {
        for url in urls {
            do {
                let uploaded = try await client.uploadTaskAttachment(workspace: ws, project: proj, taskID: id, fileURL: url)
                attachments.append(uploaded)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        onChanged?()
    }

    func attachmentData(_ attachment: FastplayAttachment) async -> Data? {
        busyAttachmentIDs.insert(attachment.id)
        defer { busyAttachmentIDs.remove(attachment.id) }
        do {
            return try await client.downloadTaskAttachment(workspace: ws, project: proj, taskID: id, attachmentID: attachment.id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteAttachment(_ attachment: FastplayAttachment) async {
        do {
            try await client.deleteTaskAttachment(workspace: ws, project: proj, taskID: id, attachmentID: attachment.id)
            attachments.removeAll { $0.id == attachment.id }
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Subtasks

    func addSubtask(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let subtask = try await client.createSubtask(workspace: ws, project: proj, taskID: id, title: trimmed)
            subtasks.append(subtask)
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Subtasks are tasks — completion toggles their status via the task route.
    func toggleSubtask(_ subtask: FastplayTask) async {
        let newStatus = subtask.isCompleted ? "todo" : "done"
        do {
            _ = try await client.updateTask(workspace: ws, project: proj, taskID: subtask.id, status: newStatus)
            if let idx = subtasks.firstIndex(where: { $0.id == subtask.id }) {
                subtasks[idx].status = newStatus
            }
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSubtask(_ subtask: FastplayTask) async {
        do {
            try await client.deleteSubtask(workspace: ws, project: proj, taskID: id, subtaskID: subtask.id)
            subtasks.removeAll { $0.id == subtask.id }
            onChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Watchers

    func toggleWatch() async {
        do {
            if isWatching {
                try await client.unwatchTask(workspace: ws, project: proj, taskID: id)
                watchers = (try? await client.watchers(workspace: ws, project: proj, taskID: id)) ?? []
            } else {
                watchers = try await client.watchTask(workspace: ws, project: proj, taskID: id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Shorthand

    private var ws: String { context.workspace }
    private var proj: String { context.project }
    private var id: String { task.id }
}
