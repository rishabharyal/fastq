import Foundation

/// Durable link from an agent session back to the Fastplay work it was
/// started for. Every field is optional: plain ⌘T shells and pre-link
/// sessions carry an empty link.
struct AgentTaskLink: Codable, Hashable {
    var workspaceID: String?
    var projectID: String?
    var taskID: String?
    var taskTitle: String?
    var taskShortCode: String?

    init(
        workspaceID: String? = nil,
        projectID: String? = nil,
        taskID: String? = nil,
        taskTitle: String? = nil,
        taskShortCode: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.taskShortCode = taskShortCode
    }

    /// No usable linkage — treat as "not linked" rather than storing it.
    var isEmpty: Bool {
        workspaceID == nil && projectID == nil && taskID == nil
            && taskTitle == nil && taskShortCode == nil
    }

    /// `nil` when there is nothing worth persisting.
    var normalized: AgentTaskLink? { isEmpty ? nil : self }

    /// Short label for the launcher list ("FQ-12" → "Fix the thing").
    var displayLabel: String? {
        if let code = taskShortCode, !code.isEmpty { return code }
        if let title = taskTitle, !title.isEmpty { return title }
        return nil
    }
}

/// Cross-window request: Board / Projects mode → Launcher agent launch.
enum StartAgentForTask {
    static let notification = Notification.Name("fastq.startAgentForTask")

    static func post(
        task: FastplayTask,
        columnName: String? = nil,
        workspaceID: String? = nil,
        projectID: String? = nil,
        taskShortCode: String? = nil,
        autoLaunch: Bool = true
    ) {
        var info: [String: Any] = [
            "taskID": task.id,
            "title": task.title,
            "autoLaunch": autoLaunch,
        ]
        if let description = task.description { info["description"] = description }
        if let status = task.status { info["status"] = status }
        if let priority = task.priority { info["priority"] = priority }
        if let columnName, !columnName.isEmpty {
            info["columnName"] = columnName
        } else if let columnName = task.resolvedColumnName {
            info["columnName"] = columnName
        }
        if let taskShortCode, !taskShortCode.isEmpty { info["taskShortCode"] = taskShortCode }
        if let workspaceID { info["workspaceID"] = workspaceID }
        if let projectID { info["projectID"] = projectID }
        else if let projectID = task.projectID ?? task.project?.id {
            info["projectID"] = projectID
        }
        NotificationCenter.default.post(name: notification, object: nil, userInfo: info)
    }

    static func linkedTask(from note: Notification) -> AgentLinkedTask? {
        guard let info = note.userInfo,
              let id = info["taskID"] as? String,
              let title = info["title"] as? String
        else { return nil }
        return AgentLinkedTask(
            id: id,
            title: title,
            description: info["description"] as? String,
            columnName: info["columnName"] as? String,
            status: info["status"] as? String,
            priority: info["priority"] as? String
        )
    }

    /// Workspace/project/task IDs carried by the notification, for the
    /// durable session link. Missing IDs stay `nil` so the caller can fill
    /// them from the currently selected board workspace/project.
    static func taskLink(from note: Notification) -> AgentTaskLink? {
        guard let info = note.userInfo else { return nil }
        return AgentTaskLink(
            workspaceID: info["workspaceID"] as? String,
            projectID: info["projectID"] as? String,
            taskID: info["taskID"] as? String,
            taskTitle: info["title"] as? String,
            taskShortCode: info["taskShortCode"] as? String
        ).normalized
    }
}
