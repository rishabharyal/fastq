import Foundation

/// Websocket connection details resolved from the backend at runtime.
///
/// Fetched from `GET /api/broadcasting/connection` rather than hardcoded so the
/// socket host can move without shipping a new client build.
struct FastplayRealtimeConfig: Decodable, Equatable {
    let enabled: Bool
    let key: String?
    let host: String?
    let port: Int?
    let scheme: String?
    let authEndpoint: String?
    let userChannel: String?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case key
        case host
        case port
        case scheme
        case authEndpoint = "auth_endpoint"
        case userChannel = "user_channel"
    }

    /// The websocket URL for the Pusher-protocol handshake.
    ///
    /// Reverb speaks the Pusher protocol, so the app key is carried in the path
    /// and identifies the *application*, not the user. It is public by design;
    /// user identity is established later, when a private channel is authorized.
    var socketURL: URL? {
        guard enabled, let host, let key, !key.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = (scheme == "http") ? "ws" : "wss"
        components.host = host
        // Railway terminates TLS on 443; sending an explicit :443 is redundant
        // and trips some proxies, so only carry a non-default port.
        if let port, port != 443, port != 80 {
            components.port = port
        }
        components.path = "/app/\(key)"
        components.queryItems = [
            URLQueryItem(name: "protocol", value: "7"),
            URLQueryItem(name: "client", value: "fastq-macos"),
            URLQueryItem(name: "version", value: "1.0"),
        ]
        return components.url
    }

    var isUsable: Bool {
        socketURL != nil && authEndpoint != nil && userChannel != nil
    }
}

/// The kind of realtime notification, mirroring the backend's payload `type`.
///
/// The Pusher event name is always `BroadcastNotificationCreated`; the backend
/// distinguishes notifications through this field, so new server-side types can
/// be added without the client needing to know about a new event name.
enum FastplayRealtimeKind: String, Decodable {
    case taskAssigned = "task.assigned"
    case commentMentioned = "comment.mentioned"
    case taskMentioned = "task.mentioned"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FastplayRealtimeKind(rawValue: raw) ?? .unknown
    }
}

/// A realtime notification delivered over the websocket.
///
/// `title` and `body` are rendered server-side, so the client can present the
/// notification immediately without a follow-up fetch.
struct FastplayRealtimeNotification: Decodable, Identifiable, Equatable {
    struct Actor: Decodable, Equatable {
        let id: String
        let name: String
    }

    let id: String
    let kind: FastplayRealtimeKind
    let title: String
    let body: String
    let taskID: String?
    let projectID: String?
    let workspaceID: String?
    let taskTitle: String?
    let commentID: String?
    let excerpt: String?
    let actor: Actor?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind = "type"
        case title
        case body
        case taskID = "task_id"
        case projectID = "project_id"
        case workspaceID = "workspace_id"
        case taskTitle = "task_title"
        case commentID = "comment_id"
        case excerpt
        case actor
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The database-channel payload and the broadcast payload share this
        // decoder; the former has no `type`, so fall back rather than failing.
        kind = (try? c.decode(FastplayRealtimeKind.self, forKey: .kind)) ?? .unknown
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? "Fastplay"
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        taskID = try? c.decodeIfPresent(String.self, forKey: .taskID)
        projectID = try? c.decodeIfPresent(String.self, forKey: .projectID)
        workspaceID = try? c.decodeIfPresent(String.self, forKey: .workspaceID)
        taskTitle = try? c.decodeIfPresent(String.self, forKey: .taskTitle)
        excerpt = try? c.decodeIfPresent(String.self, forKey: .excerpt)
        actor = try? c.decodeIfPresent(Actor.self, forKey: .actor)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        // Comments use an integer primary key while everything else is a UUID,
        // so this arrives as a number in some payloads and a string in others.
        if let asString = try? c.decodeIfPresent(String.self, forKey: .commentID) {
            commentID = asString
        } else if let asInt = try? c.decodeIfPresent(Int.self, forKey: .commentID) {
            commentID = String(asInt)
        } else {
            commentID = nil
        }
    }
}
