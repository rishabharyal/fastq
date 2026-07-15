import Foundation

enum FastplayAPIError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case decoding(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Not signed in."
        case .unauthorized: return "Session expired — sign in again."
        case .http(let code, let body): return "Request failed (\(code)): \(body)"
        case .decoding(let detail): return "Unexpected response: \(detail)"
        case .message(let m): return m
        }
    }
}

/// Thin HTTP client for https://web-production-19fc4.up.railway.app/api
actor FastplayAPIClient {
    static let shared = FastplayAPIClient()

    static let baseURL = URL(string: "https://web-production-19fc4.up.railway.app")!

    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private var accessToken: String?
    private var refreshToken: String?
    private var refreshTask: Task<Void, Error>?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    func setTokens(access: String?, refresh: String?) {
        accessToken = access
        refreshToken = refresh
    }

    var hasAccessToken: Bool { accessToken != nil }

    // MARK: - Auth

    func login(email: String, password: String) async throws -> FastplayTokenPair {
        let body: [String: String] = [
            "email": email,
            "password": password,
            "device_name": "Fastq macOS",
        ]
        let pair: FastplayTokenPair = try await postPublic("/api/auth/login", body: body)
        accessToken = pair.accessToken
        refreshToken = pair.refreshToken
        return pair
    }

    func register(name: String, email: String, password: String) async throws -> FastplayTokenPair {
        let body: [String: String] = [
            "name": name,
            "email": email,
            "password": password,
            "password_confirmation": password,
            "device_name": "Fastq macOS",
        ]
        let pair: FastplayTokenPair = try await postPublic("/api/auth/register", body: body)
        accessToken = pair.accessToken
        refreshToken = pair.refreshToken
        return pair
    }

    func refreshTokens() async throws -> FastplayTokenPair {
        guard let refreshToken else { throw FastplayAPIError.unauthorized }
        struct Body: Encodable { let refresh_token: String }
        let pair: FastplayTokenPair = try await postPublic("/api/auth/refresh", body: Body(refresh_token: refreshToken))
        accessToken = pair.accessToken
        self.refreshToken = pair.refreshToken
        return pair
    }

    func logout() async {
        if let refreshToken, accessToken != nil {
            struct Body: Encodable { let refresh_token: String }
            _ = try? await postAuthed("/api/auth/logout", body: Body(refresh_token: refreshToken)) as FastplayMessageOnly?
        }
        accessToken = nil
        refreshToken = nil
    }

    func me() async throws -> FastplayUser {
        try await getAuthed("/api/auth/me")
    }

    // MARK: - Workspaces / projects / board / tasks

    func workspaces() async throws -> [FastplayWorkspace] {
        try await getAuthed("/api/workspaces")
    }

    func createWorkspace(name: String, description: String? = nil) async throws -> FastplayWorkspace {
        var body: [String: String] = ["name": name]
        if let description, !description.isEmpty { body["description"] = description }
        return try await postAuthed("/api/workspaces", body: body)
    }

    func projects(workspace: String) async throws -> [FastplayProject] {
        try await getAuthed("/api/workspaces/\(enc(workspace))/projects")
    }

    func createProject(workspace: String, name: String, description: String? = nil, color: String? = nil) async throws -> FastplayProject {
        var body: [String: String] = ["name": name]
        if let description, !description.isEmpty { body["description"] = description }
        if let color, !color.isEmpty { body["color"] = color }
        return try await postAuthed("/api/workspaces/\(enc(workspace))/projects", body: body)
    }

    func board(workspace: String, project: String) async throws -> FastplayBoard {
        try await getAuthed("/api/workspaces/\(enc(workspace))/projects/\(enc(project))/board")
    }

    func createTask(
        workspace: String,
        project: String,
        title: String,
        description: String? = nil,
        columnID: String? = nil,
        priority: String? = nil
    ) async throws -> FastplayTask {
        var body: [String: String] = ["title": title]
        if let description, !description.isEmpty { body["description"] = description }
        if let columnID { body["board_column_id"] = columnID }
        if let priority, !priority.isEmpty { body["priority"] = priority }
        return try await postAuthed("/api/workspaces/\(enc(workspace))/projects/\(enc(project))/tasks", body: body)
    }

    func updateTask(
        workspace: String,
        project: String,
        taskID: String,
        title: String? = nil,
        description: String? = nil,
        priority: String? = nil,
        status: String? = nil
    ) async throws -> FastplayTask {
        var body: [String: String] = [:]
        if let title { body["title"] = title }
        if let description { body["description"] = description }
        if let priority { body["priority"] = priority }
        if let status { body["status"] = status }
        return try await putAuthed("/api/workspaces/\(enc(workspace))/projects/\(enc(project))/tasks/\(enc(taskID))", body: body)
    }

    func deleteTask(workspace: String, project: String, taskID: String) async throws {
        let _: FastplayMessageOnly = try await deleteAuthed("/api/workspaces/\(enc(workspace))/projects/\(enc(project))/tasks/\(enc(taskID))")
    }

    func moveTask(
        workspace: String,
        project: String,
        taskID: String,
        columnID: String,
        position: Int? = nil
    ) async throws -> FastplayTask {
        var body: [String: AnyEncodable] = [
            "board_column_id": AnyEncodable(columnID),
        ]
        if let position {
            body["position"] = AnyEncodable(position)
        }
        return try await postAuthed("/api/workspaces/\(enc(workspace))/projects/\(enc(project))/tasks/\(enc(taskID))/move", body: body)
    }

    /// POST multipart `file` → `/tasks/{task}/attachments`
    func uploadTaskAttachment(
        workspace: String,
        project: String,
        taskID: String,
        fileURL: URL
    ) async throws -> FastplayAttachment {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let mime = Self.mimeType(for: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        func append(_ string: String) {
            if let chunk = string.data(using: .utf8) { body.append(chunk) }
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        return try await requestMultipart(
            "/api/workspaces/\(enc(workspace))/projects/\(enc(project))/tasks/\(enc(taskID))/attachments",
            boundary: boundary,
            body: body
        )
    }

    // MARK: - Internals

    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"
        case "json": return "application/json"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    private func enc(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func getAuthed<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "GET", bodyData: nil, authed: true)
    }

    private func postAuthed<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request(path, method: "POST", bodyData: try encoder.encode(body), authed: true)
    }

    private func putAuthed<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request(path, method: "PUT", bodyData: try encoder.encode(body), authed: true)
    }

    private func deleteAuthed<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, method: "DELETE", bodyData: nil, authed: true)
    }

    private func postPublic<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request(path, method: "POST", bodyData: try encoder.encode(body), authed: false)
    }

    private func requestMultipart<T: Decodable>(
        _ path: String,
        boundary: String,
        body: Data,
        didRefresh: Bool = false
    ) async throws -> T {
        let full = URL(string: path, relativeTo: Self.baseURL)!.absoluteURL
        var req = URLRequest(url: full)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let accessToken else { throw FastplayAPIError.notConfigured }
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FastplayAPIError.message("No HTTP response.")
        }

        if http.statusCode == 401, !didRefresh {
            _ = try await refreshTokens()
            return try await requestMultipart(path, boundary: boundary, body: body, didRefresh: true)
        }

        return try decodeResponse(data: data, status: http.statusCode)
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String,
        bodyData: Data?,
        authed: Bool,
        didRefresh: Bool = false
    ) async throws -> T {
        let full = URL(string: path, relativeTo: Self.baseURL)!.absoluteURL

        var req = URLRequest(url: full)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
        }
        if authed {
            guard let accessToken else { throw FastplayAPIError.notConfigured }
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FastplayAPIError.message("No HTTP response.")
        }

        if http.statusCode == 401, authed, !didRefresh {
            _ = try await refreshTokens()
            return try await request(path, method: method, bodyData: bodyData, authed: authed, didRefresh: true)
        }

        return try decodeResponse(data: data, status: http.statusCode)
    }

    private func decodeResponse<T: Decodable>(data: Data, status: Int) throws -> T {
        if status == 204 {
            if let empty = FastplayMessageOnly(success: true, message: nil) as? T {
                return empty
            }
        }

        if !(200..<300).contains(status) {
            let text = String(data: data, encoding: .utf8) ?? ""
            if let env = try? decoder.decode(FastplayEnvelope<EmptyData>.self, from: data),
               let message = env.message {
                throw FastplayAPIError.message(message)
            }
            throw FastplayAPIError.http(status, String(text.prefix(200)))
        }

        if let envelope = try? decoder.decode(FastplayEnvelope<T>.self, from: data) {
            if let payload = envelope.data {
                return payload
            }
            if envelope.success == false {
                throw FastplayAPIError.message(envelope.message ?? "Request failed.")
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FastplayAPIError.decoding(error.localizedDescription)
        }
    }

    private struct EmptyData: Decodable {}
}

/// Type-erased Encodable for mixed JSON bodies.
struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) {
        encodeFunc = { encoder in try value.encode(to: encoder) }
    }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}
