import Foundation

/// Launch-time extras so an AI CLI can report `AgentActivity` (OSC titles, etc.).
struct AgentLaunchAugmentation {
    /// Raw argv tokens inserted after the executable (e.g. `--settings`, path).
    var extraArguments: [String] = []
    /// Optional setup before the command string is built (write hook files, …).
    var prepare: (() throws -> Void)?
}

/// Per-tool strategy for teaching an AI CLI to emit Fastq activity signals.
/// Terminal-side inference is shared (`AgentActivityInterpreter`) for every tool.
protocol AgentActivityAdapter {
    var toolID: String { get }
    func prepareLaunch() throws -> AgentLaunchAugmentation
}

/// Default: no launch hooks. Status still flows from OSC + PTY heuristics in Terminal.
struct DefaultActivityAdapter: AgentActivityAdapter {
    let toolID: String

    func prepareLaunch() throws -> AgentLaunchAugmentation {
        AgentLaunchAugmentation()
    }
}

/// Resolves the adapter for any `AgentToolKind`. New CLIs register here.
enum AgentActivityRegistry {
    static func adapter(for kind: AgentToolKind) -> any AgentActivityAdapter {
        switch kind {
        case .claudeCode:
            return ClaudeCodeActivityAdapter()
        case .cursorCLI, .codexCLI, .grokAgent, .openCode:
            // Same path as unknown tools today — Terminal heuristics + OSC contract.
            // Add a dedicated adapter when the vendor exposes hooks/flags.
            return DefaultActivityAdapter(toolID: kind.rawValue)
        }
    }

    static func prepare(for kind: AgentToolKind) throws -> AgentLaunchAugmentation {
        try adapter(for: kind).prepareLaunch()
    }
}
