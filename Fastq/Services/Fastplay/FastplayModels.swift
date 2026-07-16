import Foundation

// MARK: - API envelope

struct FastplayEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let message: String?
    let data: T?
    let errors: [String: [String]]?
}

struct FastplayMessageOnly: Decodable {
    let success: Bool?
    let message: String?
}

// MARK: - Auth

struct FastplayTokenPair: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var tokenType: String
    var expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct FastplayUser: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var email: String
    var avatarURL: String?
    var currentWorkspaceID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case avatarURL = "avatar_url"
        case currentWorkspaceID = "current_workspace_id"
    }

    init(id: String, name: String, email: String, avatarURL: String? = nil, currentWorkspaceID: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
        self.currentWorkspaceID = currentWorkspaceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let i = try? c.decode(Int.self, forKey: .id) {
            id = String(i)
        } else {
            id = UUID().uuidString
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        if let s = try? c.decode(String.self, forKey: .currentWorkspaceID) {
            currentWorkspaceID = s
        } else {
            currentWorkspaceID = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try c.encodeIfPresent(currentWorkspaceID, forKey: .currentWorkspaceID)
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let chars = parts.compactMap(\.first).map(String.init).joined()
        return chars.isEmpty ? String(email.prefix(1)).uppercased() : chars.uppercased()
    }
}

// MARK: - Workspace / Project / Board / Task

struct FastplayWorkspace: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var slug: String
    var description: String?
    var myRole: String?
    var membersCount: Int?
    var projectsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, description
        case myRole = "my_role"
        case membersCount = "members_count"
        case projectsCount = "projects_count"
    }

    /// Path key for nested routes.
    var routeKey: String { slug.isEmpty ? id : slug }
}

struct FastplayProject: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var slug: String
    var description: String?
    var color: String?
    var boardID: String?
    var workspaceID: String?
    var tasksCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, description, color
        case boardID = "board_id"
        case workspaceID = "workspace_id"
        case tasksCount = "tasks_count"
    }

    var routeKey: String { id }
}

struct FastplayBoard: Codable, Identifiable, Equatable {
    var id: String
    var name: String?
    var columns: [FastplayColumn]
}

struct FastplayColumn: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var position: Int
    var color: String?
    var tasks: [FastplayTask]
}

struct FastplayTaskColumnRef: Codable, Equatable, Hashable {
    var id: String
    var name: String
}

struct FastplayTaskProjectRef: Codable, Equatable, Hashable {
    var id: String
    var name: String
    var slug: String?
    var workspaceID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case workspaceID = "workspace_id"
    }
}

struct FastplayTask: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var description: String?
    var status: String?
    var priority: String?
    var position: Int?
    var boardColumnID: String?
    var projectID: String?
    var dueDate: String?
    /// Present on list/search responses when the API eager-loads the column.
    var column: FastplayTaskColumnRef?
    /// Present on list/search responses when the API eager-loads the project.
    var project: FastplayTaskProjectRef?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, position, column, project
        case boardColumnID = "board_column_id"
        case projectID = "project_id"
        case dueDate = "due_date"
    }

    var resolvedColumnName: String? {
        if let name = column?.name, !name.isEmpty { return name }
        return nil
    }
}

/// One row in the `#` task mention popup.
struct TaskMentionItem: Identifiable, Equatable, Hashable {
    var id: String { task.id }
    var task: FastplayTask
    var columnName: String

    init(task: FastplayTask, columnName: String? = nil) {
        self.task = task
        self.columnName = columnName
            ?? task.resolvedColumnName
            ?? task.status
            ?? "Task"
    }

    init(column: FastplayColumn, task: FastplayTask) {
        self.task = task
        self.columnName = column.name
    }

    var linkedTask: AgentLinkedTask {
        AgentLinkedTask(
            id: task.id,
            title: task.title,
            description: task.description,
            columnName: columnName,
            status: task.status,
            priority: task.priority
        )
    }
}

struct FastplayAttachment: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var size: Int?
    var path: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, path
    }
}
