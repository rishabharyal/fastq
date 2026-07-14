import Foundation

enum AgentToolKind: String, Codable, CaseIterable, Identifiable {
    case cursorCLI
    case claudeCode
    case codexCLI
    case grokAgent
    case openCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cursorCLI: return "Cursor Agent"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .grokAgent: return "Grok Agent"
        case .openCode: return "OpenCode"
        }
    }

    var shortName: String {
        switch self {
        case .cursorCLI: return "Cursor"
        case .claudeCode: return "Claude"
        case .codexCLI: return "Codex"
        case .grokAgent: return "Grok"
        case .openCode: return "OpenCode"
        }
    }

    var systemImage: String {
        switch self {
        case .cursorCLI: return "chevron.left.forwardslash.chevron.right"
        case .claudeCode: return "sparkles"
        case .codexCLI: return "terminal"
        case .grokAgent: return "bolt.fill"
        case .openCode: return "rectangle.and.terminal"
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
        }
    }

    /// All supported tools launch as CLI agents inside Fastq Terminal.
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

struct PromptAttachment: Identifiable, Hashable {
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
}

enum AgentModelOption: String, CaseIterable, Identifiable, Codable {
    case auto
    case sonnet
    case opus
    case gpt4o
    case gpt5
    case o3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .sonnet: return "Claude Sonnet"
        case .opus: return "Claude Opus"
        case .gpt4o: return "GPT-4o"
        case .gpt5: return "GPT-5"
        case .o3: return "o3"
        }
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
    /// When true, focus/quit go through Fastq Terminal IPC instead of AppleScript.
    var hostedInFastqTerminal: Bool = false
    var status: SessionStatus

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
        let host = hostedInFastqTerminal ? "Fastq Terminal" : tool.displayName
        return "\(host) · \(projectName)"
    }
}
