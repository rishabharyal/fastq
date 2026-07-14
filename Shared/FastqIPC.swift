import Foundation

/// Unix socket path shared by Fastq launcher ↔ Fastq Terminal.
public enum FastqIPC {
    public static let socketPath: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent("Library/Application Support/fastq/fastq.sock")
    }()

    public static let supportDirectory: String = {
        let home = NSHomeDirectory()
        return (home as NSString).appendingPathComponent("Library/Application Support/fastq")
    }()
}

public enum FastqIPCMessage: Codable, Sendable {
    case createSession(CreateSessionRequest)
    case focusSession(sessionID: UUID)
    case selectSession(sessionID: UUID)
    case quitSession(sessionID: UUID)
    case sendText(sessionID: UUID, text: String)
    case cycleSession(delta: Int)
    case listSessions
    case ping

    case sessionCreated(SessionInfo)
    case sessionList([SessionInfo])
    case ok
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum MessageType: String, Codable {
        case createSession, focusSession, selectSession, quitSession, sendText, cycleSession, listSessions, ping
        case sessionCreated, sessionList, ok, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .createSession:
            self = .createSession(try container.decode(CreateSessionRequest.self, forKey: .payload))
        case .focusSession:
            let payload = try container.decode(IDPayload.self, forKey: .payload)
            self = .focusSession(sessionID: payload.sessionID)
        case .selectSession:
            let payload = try container.decode(IDPayload.self, forKey: .payload)
            self = .selectSession(sessionID: payload.sessionID)
        case .quitSession:
            let payload = try container.decode(IDPayload.self, forKey: .payload)
            self = .quitSession(sessionID: payload.sessionID)
        case .sendText:
            let payload = try container.decode(SendTextPayload.self, forKey: .payload)
            self = .sendText(sessionID: payload.sessionID, text: payload.text)
        case .cycleSession:
            let payload = try container.decode(CyclePayload.self, forKey: .payload)
            self = .cycleSession(delta: payload.delta)
        case .listSessions:
            self = .listSessions
        case .ping:
            self = .ping
        case .sessionCreated:
            self = .sessionCreated(try container.decode(SessionInfo.self, forKey: .payload))
        case .sessionList:
            self = .sessionList(try container.decode([SessionInfo].self, forKey: .payload))
        case .ok:
            self = .ok
        case .error:
            let payload = try container.decode(ErrorPayload.self, forKey: .payload)
            self = .error(payload.message)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createSession(let req):
            try container.encode(MessageType.createSession, forKey: .type)
            try container.encode(req, forKey: .payload)
        case .focusSession(let id):
            try container.encode(MessageType.focusSession, forKey: .type)
            try container.encode(IDPayload(sessionID: id), forKey: .payload)
        case .selectSession(let id):
            try container.encode(MessageType.selectSession, forKey: .type)
            try container.encode(IDPayload(sessionID: id), forKey: .payload)
        case .quitSession(let id):
            try container.encode(MessageType.quitSession, forKey: .type)
            try container.encode(IDPayload(sessionID: id), forKey: .payload)
        case .sendText(let id, let text):
            try container.encode(MessageType.sendText, forKey: .type)
            try container.encode(SendTextPayload(sessionID: id, text: text), forKey: .payload)
        case .cycleSession(let delta):
            try container.encode(MessageType.cycleSession, forKey: .type)
            try container.encode(CyclePayload(delta: delta), forKey: .payload)
        case .listSessions:
            try container.encode(MessageType.listSessions, forKey: .type)
        case .ping:
            try container.encode(MessageType.ping, forKey: .type)
        case .sessionCreated(let info):
            try container.encode(MessageType.sessionCreated, forKey: .type)
            try container.encode(info, forKey: .payload)
        case .sessionList(let list):
            try container.encode(MessageType.sessionList, forKey: .type)
            try container.encode(list, forKey: .payload)
        case .ok:
            try container.encode(MessageType.ok, forKey: .type)
        case .error(let message):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(ErrorPayload(message: message), forKey: .payload)
        }
    }
}

public struct CreateSessionRequest: Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var title: String
    public var projectName: String
    public var projectPath: String
    public var command: String
    public var prompt: String
    public var tool: String

    public init(
        sessionID: UUID = UUID(),
        title: String,
        projectName: String,
        projectPath: String,
        command: String,
        prompt: String,
        tool: String
    ) {
        self.sessionID = sessionID
        self.title = title
        self.projectName = projectName
        self.projectPath = projectPath
        self.command = command
        self.prompt = prompt
        self.tool = tool
    }
}

public struct SessionInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var projectName: String
    public var projectPath: String
    public var tool: String
    public var pid: Int32?
    public var isRunning: Bool

    public init(
        id: UUID,
        title: String,
        projectName: String,
        projectPath: String,
        tool: String,
        pid: Int32? = nil,
        isRunning: Bool = true
    ) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.projectPath = projectPath
        self.tool = tool
        self.pid = pid
        self.isRunning = isRunning
    }
}

private struct IDPayload: Codable {
    var sessionID: UUID
}

private struct SendTextPayload: Codable {
    var sessionID: UUID
    var text: String
}

private struct CyclePayload: Codable {
    var delta: Int
}

private struct ErrorPayload: Codable {
    var message: String
}

/// Length-prefixed JSON framing over a UNIX socket.
public enum FastqIPCFraming {
    public static func encode(_ message: FastqIPCMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        var length = UInt32(json.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(json)
        return data
    }

    public static func decode(from buffer: inout Data) throws -> FastqIPCMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard buffer.count >= 4 + length else { return nil }
        let json = buffer.subdata(in: 4..<(4 + length))
        buffer.removeSubrange(0..<(4 + length))
        return try JSONDecoder().decode(FastqIPCMessage.self, from: json)
    }
}
