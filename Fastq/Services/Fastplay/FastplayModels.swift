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

struct FastplayUser: Codable, Equatable, Identifiable, Hashable {
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
    var reporterID: String?
    var startDate: String?
    var dueDate: String?
    var createdAt: String?
    /// Present on list/search responses when the API eager-loads the column.
    var column: FastplayTaskColumnRef?
    /// Present on list/search responses when the API eager-loads the project.
    var project: FastplayTaskProjectRef?
    var reporter: FastplayUser?
    var assignees: [FastplayUser]?
    var labels: [FastplayLabel]?
    var subtasksCount: Int?
    var commentsCount: Int?
    var attachmentsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, position, column, project
        case reporter, assignees, labels
        case boardColumnID = "board_column_id"
        case projectID = "project_id"
        case reporterID = "reporter_id"
        case startDate = "start_date"
        case dueDate = "due_date"
        case createdAt = "created_at"
        case subtasksCount = "subtasks_count"
        case commentsCount = "comments_count"
        case attachmentsCount = "attachments_count"
    }

    var resolvedColumnName: String? {
        if let name = column?.name, !name.isEmpty { return name }
        return nil
    }

    var isCompleted: Bool {
        let s = (status ?? "").lowercased()
        return s == "done" || s == "completed"
    }
}

struct FastplayLabel: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var color: String?
}

struct FastplayWatcher: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case avatarURL = "avatar_url"
    }
}

struct FastplayComment: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var body: String
    var parentID: String?
    var author: FastplayUser?
    var replies: [FastplayComment]?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, body, author, replies
        case parentID = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
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
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        if let s = try? c.decode(String.self, forKey: .parentID) {
            parentID = s
        } else if let i = try? c.decode(Int.self, forKey: .parentID) {
            parentID = String(i)
        } else {
            parentID = nil
        }
        author = try c.decodeIfPresent(FastplayUser.self, forKey: .author)
        replies = try c.decodeIfPresent([FastplayComment].self, forKey: .replies)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct FastplayActivity: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var type: String
    var actor: FastplayUser?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, actor
        case createdAt = "created_at"
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
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        actor = try c.decodeIfPresent(FastplayUser.self, forKey: .actor)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

/// Parses/format the backend's date strings (`2026-07-22` or full ISO8601).
enum FastplayDates {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let d = isoFractional.date(from: string) { return d }
        if let d = iso.date(from: string) { return d }
        return day.date(from: String(string.prefix(10)))
    }

    /// `yyyy-MM-dd` — what the API's `date` validation expects.
    static func apiDay(_ date: Date) -> String {
        day.string(from: date)
    }

    static func displayDay(_ string: String?) -> String? {
        guard let date = parse(string) else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    static func relative(_ string: String?) -> String? {
        guard let date = parse(string) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Everything the create-task composer can collect. All fields except
/// `title` are optional; the API accepts them in one POST.
struct FastplayTaskDraft {
    var title: String = ""
    var description: String = ""
    var columnID: String?
    var priority: String?
    var startDate: Date?
    var dueDate: Date?
    var labelIDs: [String] = []
    var assigneeIDs: [String] = []
    var attachmentURLs: [URL] = []
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
    var createdAt: String?
    var uploadedBy: FastplayUser?

    enum CodingKeys: String, CodingKey {
        case id, name, size, path
        case createdAt = "created_at"
        case uploadedBy = "uploaded_by"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Attachment ids are integers in AttachmentResource but strings when
        // nested inside TaskResource — accept both.
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let i = try? c.decode(Int.self, forKey: .id) {
            id = String(i)
        } else {
            id = UUID().uuidString
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "file"
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        uploadedBy = try c.decodeIfPresent(FastplayUser.self, forKey: .uploadedBy)
    }

    var sizeLabel: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
