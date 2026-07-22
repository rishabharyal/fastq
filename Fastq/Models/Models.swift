import Foundation

/// What the launcher does with a submitted prompt.
enum LauncherMode: String, Codable, CaseIterable {
    /// General LLM chat (Anthropic / OpenAI APIs) with attachments.
    case chat
    /// Launch a coding agent in Fastq Terminal (the original behavior).
    case agent
    /// Compose a Fastplay board task (workspace / project / column).
    case board

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .agent: return "desktopcomputer"
        case .board: return "checklist"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .chat: return "Chat mode"
        case .agent: return "Agent mode"
        case .board: return "Projects mode"
        }
    }

    /// Click-to-cycle order: Chat → Agent → Projects → Chat.
    var next: LauncherMode {
        switch self {
        case .chat: return .agent
        case .agent: return .board
        case .board: return .chat
        }
    }
}

enum AgentToolKind: String, Codable, CaseIterable, Identifiable {
    case cursorCLI
    case claudeCode
    case codexCLI
    case grokAgent
    case openCode
    case shell

    var id: String { rawValue }

    /// Coding agents shown in the launcher tool picker. Headless mode
    /// currently supports Claude Code and Cursor only (other cases remain
    /// for decoding old persisted settings).
    static var agentCases: [AgentToolKind] {
        [.claudeCode, .cursorCLI]
    }

    var displayName: String {
        switch self {
        case .cursorCLI: return "Cursor Agent"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .grokAgent: return "Grok Agent"
        case .openCode: return "OpenCode"
        case .shell: return "Terminal"
        }
    }

    var shortName: String {
        switch self {
        case .cursorCLI: return "Cursor"
        case .claudeCode: return "Claude"
        case .codexCLI: return "Codex"
        case .grokAgent: return "Grok"
        case .openCode: return "OpenCode"
        case .shell: return "Shell"
        }
    }

    var systemImage: String {
        switch self {
        case .cursorCLI: return "chevron.left.forwardslash.chevron.right"
        case .claudeCode: return "sparkles"
        case .codexCLI: return "terminal"
        case .grokAgent: return "bolt.fill"
        case .openCode: return "rectangle.and.terminal"
        case .shell: return "terminal.fill"
        }
    }

    /// Default executable name or absolute path.
    var defaultCommand: String {
        let home = NSHomeDirectory()
        switch self {
        case .cursorCLI: return "\(home)/.local/bin/cursor-agent"
        case .claudeCode: return "claude"
        case .codexCLI: return "codex"
        case .grokAgent: return "\(home)/.grok/bin/agent"
        case .openCode: return "\(home)/.opencode/bin/opencode"
        case .shell: return "/bin/zsh"
        }
    }

    /// Extra well-known install locations checked during detection.
    var searchPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .cursorCLI:
            return [
                "\(home)/.local/bin/cursor-agent",
                "\(home)/.local/bin/agent",
                "\(home)/.cursor/bin/cursor-agent",
                "\(home)/.cursor/bin/agent",
                "/opt/homebrew/bin/cursor-agent",
                "/usr/local/bin/cursor-agent"
            ]
        case .claudeCode:
            return [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
        case .codexCLI:
            return [
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        case .grokAgent:
            return [
                "\(home)/.grok/bin/agent",
                "\(home)/.local/bin/grok",
                "/opt/homebrew/bin/grok"
            ]
        case .openCode:
            return [
                "\(home)/.opencode/bin/opencode",
                "\(home)/.local/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/usr/local/bin/opencode"
            ]
        case .shell:
            return ["/bin/zsh", "/bin/bash"]
        }
    }

    /// Coding agents launch in Fastq Terminal; shell is the plain PTY tab.
    var launchesInTerminal: Bool { true }

    var hostAppName: String { "Fastq Terminal" }
}

struct ProjectFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        self.id = UUID()
        self.name = url.lastPathComponent
        self.path = path
    }
}

struct ToolConfig: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: AgentToolKind
    var enabled: Bool
    var commandPath: String
    var displayName: String

    init(
        id: UUID = UUID(),
        kind: AgentToolKind,
        enabled: Bool = true,
        commandPath: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.commandPath = commandPath ?? kind.defaultCommand
        self.displayName = displayName ?? kind.displayName
    }
}

struct PromptAttachment: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var path: String
    var isImage: Bool

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.name = url.lastPathComponent
        self.path = url.path
        let ext = url.pathExtension.lowercased()
        self.isImage = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"].contains(ext)
    }

    /// Restore a previously persisted attachment (durable Application Support path).
    init(id: UUID, name: String, path: String, isImage: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.isImage = isImage
    }
}

/// Model choices for the headless agent CLIs. Values are the CLIs' stable
/// aliases (both `claude --model` and `cursor-agent --model` accept them);
/// aliases track the latest model in each family so this list doesn't rot.
enum AgentModelOption: String, CaseIterable, Identifiable, Codable {
    case auto
    case fable
    case opus
    case sonnet
    case haiku
    /// Cursor's in-house fast agent model.
    case composer

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Legacy persisted values (gpt4o / gpt5 / o3 …) fall back to auto.
        self = AgentModelOption(rawValue: raw) ?? .auto
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .fable: return "Claude Fable"
        case .opus: return "Claude Opus"
        case .sonnet: return "Claude Sonnet"
        case .haiku: return "Claude Haiku"
        case .composer: return "Composer"
        }
    }

    /// The models each tool actually accepts.
    static func options(for tool: AgentToolKind) -> [AgentModelOption] {
        switch tool {
        case .claudeCode: return [.auto, .fable, .opus, .sonnet, .haiku]
        case .cursorCLI: return [.auto, .composer, .opus, .sonnet]
        default: return [.auto]
        }
    }

    /// Alias passed to `--model` (omitted entirely for `.auto`).
    func cliModelFlag(for tool: AgentToolKind) -> String {
        rawValue
    }
}

struct AgentSession: Identifiable, Hashable {
    var id: UUID
    var tool: AgentToolKind
    var projectName: String
    var projectPath: String
    var promptPreview: String
    var model: AgentModelOption
    var startedAt: Date
    var processIdentifier: pid_t?
    var terminalWindowID: Int?
    var status: SessionStatus
    /// Claude (and any AI CLI) turn state from Terminal activity bridge.
    var activity: AgentActivity = .idle
    /// Headless chat session (AgentChatStore) instead of a PTY.
    var isChat = false

    enum SessionStatus: String, Hashable {
        case launching
        case running
        case exited
    }

    var title: String {
        let trimmed = promptPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "\(tool.shortName) · \(projectName)"
        }
        let preview = trimmed.count > 48 ? String(trimmed.prefix(45)) + "…" : trimmed
        return preview
    }

    var subtitle: String {
        if tool == .shell {
            return "Terminal · \(projectName)"
        }
        return "\(tool.displayName) · \(projectName)"
    }

    /// Label shown in the Active Windows row.
    var statusDisplayLabel: String {
        switch status {
        case .launching: return "Launching"
        case .exited: return "Exited"
        case .running:
            return activity.launcherLabel
        }
    }
}

/// Agent turn state mirrored from OSC titles / PTY heuristics.
enum AgentActivity: String, Codable, Sendable, Hashable {
    case idle
    case working
    case waiting
    case done

    static let titlePrefix = "fastq:"

    static func parseTitle(_ title: String) -> AgentActivity? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(titlePrefix) else { return nil }
        let raw = String(trimmed.dropFirst(titlePrefix.count)).lowercased()
        let token = raw.split(whereSeparator: { $0 == " " || $0 == "·" || $0 == "|" }).first
            .map(String.init) ?? raw
        return AgentActivity(rawValue: token)
    }

    var launcherLabel: String {
        switch self {
        case .idle: return "Running"
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        }
    }
}
