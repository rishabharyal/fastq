import Foundation

// MARK: - Engine events

/// Unified event stream both headless engines (claude / cursor-agent) map into.
/// The chat UI and store only ever see these.
enum AgentEngineEvent {
    case sessionStarted(engineSessionID: String, model: String?)
    /// Incremental main-conversation text (partial streaming).
    case textDelta(String)
    /// A complete assistant text block (canonical; replaces streamed text).
    /// `key` dedupes Claude's message snapshots, which re-include earlier
    /// blocks on every emission (messageID#blockIndex). nil = no dedupe.
    case assistantText(String, key: String?)
    case toolStarted(id: String, name: String, summary: String, isSubagent: Bool)
    case toolFinished(id: String, ok: Bool)
    /// Reasoning is underway (cursor thinking deltas / claude thinking blocks).
    case thinking
    case retrying(attempt: Int, reason: String)
    case finished(ok: Bool, resultText: String, costUSD: Double?, durationMs: Int?)
    case processFailed(String)
}

// MARK: - Transcript items (persisted)

struct ToolCallRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Compact argument summary shown next to the name ("grep -rn … src/").
    var summary: String
    var startedAt: Date
    var finishedAt: Date?
    /// nil while running.
    var ok: Bool?
    var isSubagent: Bool = false

    var durationLabel: String? {
        guard let finishedAt else { return nil }
        let ms = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }
}

struct AskQuestionOption: Codable, Equatable, Hashable {
    var label: String
    var description: String?
}

struct AskQuestion: Codable, Equatable, Identifiable {
    var question: String
    var header: String?
    var options: [AskQuestionOption]
    var multiSelect: Bool

    var id: String { question }
}

struct QuestionRecord: Codable, Equatable {
    var questions: [AskQuestion]
    /// question text → chosen label(s), filled once answered.
    var answers: [String: String] = [:]
    var answered = false
}

struct PermissionRecord: Codable, Equatable {
    var toolName: String
    var summary: String
    /// nil = pending, true = allowed, false = denied.
    var allowed: Bool?
}

struct RunResultRecord: Codable, Equatable {
    var ok: Bool
    var text: String
    var costUSD: Double?
    var durationMs: Int?
}

/// One row of a conversation transcript.
struct AgentChatItem: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var kind: Kind

    enum Kind: Codable, Equatable {
        case user(text: String, attachments: [String])
        case assistantText(String)
        case toolCalls([ToolCallRecord])
        case question(QuestionRecord)
        case permission(PermissionRecord)
        case result(RunResultRecord)
        case error(String)
    }

    init(kind: Kind, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
    }
}

// MARK: - Permission presets

/// Maps to CLI permission flags. `askMe` routes prompts through the
/// in-app approval bridge (Claude only).
enum AgentPermissionPreset: String, Codable, CaseIterable, Identifiable {
    case askMe
    case acceptEdits
    case fullAuto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askMe: return "Ask before actions"
        case .acceptEdits: return "Accept edits"
        case .fullAuto: return "Full auto"
        }
    }

    var detail: String {
        switch self {
        case .askMe: return "Approve edits and commands as they happen"
        case .acceptEdits: return "File edits run freely; commands still ask"
        case .fullAuto: return "Everything runs without asking"
        }
    }

    var systemImage: String {
        switch self {
        case .askMe: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .fullAuto: return "bolt.fill"
        }
    }
}

// MARK: - Bridge payloads

/// Request relayed from the MCP approve helper to the app.
struct BridgeRequest: Codable {
    var token: String
    var toolName: String
    var input: AnyJSON

    enum CodingKeys: String, CodingKey {
        case token
        case toolName = "tool_name"
        case input
    }
}

/// Response written back to the helper — exactly the permission-result JSON
/// Claude Code expects from a permission prompt tool.
enum BridgeResponse {
    case allow(updatedInput: AnyJSON)
    case deny(message: String)

    var jsonString: String {
        switch self {
        case .allow(let input):
            let inner = input.jsonString
            return "{\"behavior\":\"allow\",\"updatedInput\":\(inner)}"
        case .deny(let message):
            let escaped = (try? JSONEncoder().encode(message)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"Denied\""
            return "{\"behavior\":\"deny\",\"message\":\(escaped)}"
        }
    }
}

// MARK: - Loose JSON

/// Minimal JSON value for payloads whose schema we pass through untouched.
enum AnyJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AnyJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: AnyJSON].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    subscript(key: String) -> AnyJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [AnyJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: AnyJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
