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
    /// `detail` carries the raw tool input (file paths, diffs, commands) so
    /// the transcript can expand a call into a full inspector.
    case toolStarted(id: String, name: String, summary: String, isSubagent: Bool, detail: ToolCallDetail?)
    /// `resultText` is the tool_result payload, already capped for storage.
    case toolFinished(id: String, ok: Bool, resultText: String?)
    /// Reasoning is underway (cursor thinking deltas / claude thinking blocks).
    case thinking
    case retrying(attempt: Int, reason: String)
    case finished(ok: Bool, resultText: String, costUSD: Double?, durationMs: Int?)
    case processFailed(String)
}

// MARK: - Transcript items (persisted)

/// How a tool call should be rendered when expanded.
enum ToolDetailKind: String, Codable, Equatable {
    case edit, write, read, bash, search, other

    /// Derived from the tool name reported by the CLI (Claude uses
    /// "Edit"/"Bash", cursor-agent uses "read"/"shell"/"search replace").
    static func infer(toolName: String) -> ToolDetailKind {
        let name = toolName.lowercased()
        if name.hasPrefix("mcp__") { return .other }
        switch name {
        case "edit", "multiedit", "multi edit", "notebookedit",
             "search replace", "searchreplace", "apply patch", "applypatch", "patch":
            return .edit
        case "write", "create", "create file", "createfile":
            return .write
        case "read", "read file", "readfile", "notebookread":
            return .read
        case "bash", "shell", "run", "terminal", "bashoutput", "run terminal cmd":
            return .bash
        case "grep", "glob", "search", "codebase search", "codebasesearch",
             "file search", "filesearch", "list dir", "listdir", "ls":
            return .search
        default:
            // Be forgiving about wording drift in either CLI.
            if name.contains("edit") || name.contains("replace") { return .edit }
            if name.contains("write") { return .write }
            if name.contains("read") { return .read }
            if name.contains("shell") || name.contains("command") { return .bash }
            if name.contains("search") || name.contains("grep") || name.contains("glob") { return .search }
            return .other
        }
    }
}

/// One old→new replacement (MultiEdit emits several per call).
struct ToolEditPatch: Codable, Equatable, Hashable {
    var oldString: String
    var newString: String
}

/// Storage caps — a single agent run can produce megabytes of tool payloads
/// and the whole transcript is re-encoded to JSON on every persist.
enum ToolDetailLimits {
    /// Per input field (file content, old/new strings, commands).
    static let field = 100_000
    /// Tool result output.
    static let result = 40_000
    /// Total across all MultiEdit patches.
    static let patches = 100_000

    static func cap(_ text: String?, _ limit: Int) -> String? {
        guard let text else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[truncated]"
    }
}

/// Raw tool input captured at `tool_use` time, ready for the detail view.
/// Every field is optional — engines change shapes and we never want a
/// missing key to cost us the whole row.
struct ToolCallDetail: Codable, Equatable {
    var kind: ToolDetailKind = .other
    var filePath: String?
    var oldString: String?
    var newString: String?
    /// Write: the full file body.
    var content: String?
    /// Bash: the command line.
    var command: String?
    /// Grep/Glob: the pattern, and the directory it was scoped to.
    var pattern: String?
    var searchPath: String?
    /// MultiEdit: every replacement in order.
    var edits: [ToolEditPatch]?
    /// Pretty-printed input for tools we have no bespoke rendering for.
    var rawInput: String?

    var isEmpty: Bool {
        filePath == nil && oldString == nil && newString == nil && content == nil
            && command == nil && pattern == nil && searchPath == nil
            && (edits?.isEmpty ?? true) && rawInput == nil
    }

    /// Applies the storage caps once, at capture time.
    func capped() -> ToolCallDetail {
        var copy = self
        copy.oldString = ToolDetailLimits.cap(oldString, ToolDetailLimits.field)
        copy.newString = ToolDetailLimits.cap(newString, ToolDetailLimits.field)
        copy.content = ToolDetailLimits.cap(content, ToolDetailLimits.field)
        copy.command = ToolDetailLimits.cap(command, ToolDetailLimits.field)
        copy.rawInput = ToolDetailLimits.cap(rawInput, ToolDetailLimits.result)
        if let edits {
            var budget = ToolDetailLimits.patches
            var kept: [ToolEditPatch] = []
            for patch in edits {
                guard budget > 0 else { break }
                let old = String(patch.oldString.prefix(budget))
                budget -= old.count
                let new = String(patch.newString.prefix(max(budget, 0)))
                budget -= new.count
                kept.append(ToolEditPatch(oldString: old, newString: new))
            }
            copy.edits = kept
        }
        return copy
    }
}

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

    // MARK: Expandable detail (all added after the first shipping format —
    // decoded with decodeIfPresent so old transcripts still load).

    var detailKind: ToolDetailKind = .other
    var filePath: String?
    var oldString: String?
    var newString: String?
    var content: String?
    var command: String?
    var pattern: String?
    var searchPath: String?
    var edits: [ToolEditPatch]?
    var rawInput: String?
    /// tool_result content, capped.
    var resultText: String?

    var durationLabel: String? {
        guard let finishedAt else { return nil }
        let ms = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }

    /// True when expanding the row would show something worth showing.
    var hasDetail: Bool {
        detail.isEmpty == false || (resultText?.isEmpty == false)
    }

    var detail: ToolCallDetail {
        ToolCallDetail(
            kind: detailKind,
            filePath: filePath,
            oldString: oldString,
            newString: newString,
            content: content,
            command: command,
            pattern: pattern,
            searchPath: searchPath,
            edits: edits,
            rawInput: rawInput
        )
    }

    mutating func apply(detail: ToolCallDetail) {
        detailKind = detail.kind
        filePath = detail.filePath
        oldString = detail.oldString
        newString = detail.newString
        content = detail.content
        command = detail.command
        pattern = detail.pattern
        searchPath = detail.searchPath
        edits = detail.edits
        rawInput = detail.rawInput
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, startedAt, finishedAt, ok, isSubagent
        case detailKind, filePath, oldString, newString, content
        case command, pattern, searchPath, edits, rawInput, resultText
    }
}

extension ToolCallRecord {
    // Explicit decoding: records written before the detail fields existed
    // must keep loading instead of failing the whole transcript.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "tool"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        isSubagent = try c.decodeIfPresent(Bool.self, forKey: .isSubagent) ?? false
        detailKind = try c.decodeIfPresent(ToolDetailKind.self, forKey: .detailKind)
            ?? ToolDetailKind.infer(toolName: name)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        oldString = try c.decodeIfPresent(String.self, forKey: .oldString)
        newString = try c.decodeIfPresent(String.self, forKey: .newString)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        searchPath = try c.decodeIfPresent(String.self, forKey: .searchPath)
        edits = try c.decodeIfPresent([ToolEditPatch].self, forKey: .edits)
        rawInput = try c.decodeIfPresent(String.self, forKey: .rawInput)
        resultText = try c.decodeIfPresent(String.self, forKey: .resultText)
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
