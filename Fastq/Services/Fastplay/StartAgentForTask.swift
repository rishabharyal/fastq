import Foundation

/// Cross-window request: Board / Projects mode → Launcher agent launch.
enum StartAgentForTask {
    static let notification = Notification.Name("fastq.startAgentForTask")

    static func post(
        task: FastplayTask,
        columnName: String? = nil,
        workspaceID: String? = nil,
        projectID: String? = nil,
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
}
