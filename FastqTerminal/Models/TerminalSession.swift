import Foundation
import Combine
import AppKit

struct TerminalWorkspace: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var abbreviatedPath: String
    var groupName: String
}

struct TerminalWorkspaceGroup: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var workspaces: [TerminalWorkspace]
}

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?
    @Published var selectedWorkspacePath: String?
    @Published var collapsedWorkspaceIDs: Set<String> = []

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var workspaces: [TerminalWorkspace] {
        var seen: [String: TerminalWorkspace] = [:]
        var order: [String] = []
        for session in sessions {
            if seen[session.projectPath] == nil {
                seen[session.projectPath] = TerminalWorkspace(
                    name: session.projectName,
                    path: session.projectPath,
                    abbreviatedPath: Self.abbreviate(session.projectPath),
                    groupName: Self.groupName(for: session.projectPath)
                )
                order.append(session.projectPath)
            }
        }
        return order.compactMap { seen[$0] }
    }

    var workspaceGroups: [TerminalWorkspaceGroup] {
        var groups: [String: [TerminalWorkspace]] = [:]
        var order: [String] = []
        for workspace in workspaces {
            if groups[workspace.groupName] == nil {
                order.append(workspace.groupName)
                groups[workspace.groupName] = []
            }
            groups[workspace.groupName]?.append(workspace)
        }
        return order.map { TerminalWorkspaceGroup(name: $0, workspaces: groups[$0] ?? []) }
    }

    func sessions(in workspacePath: String) -> [TerminalSession] {
        sessions.filter { $0.projectPath == workspacePath }
    }

    func create(from request: CreateSessionRequest) throws -> TerminalSession {
        let session = TerminalSession(request: request)
        try session.start()
        sessions.append(session)
        selectedWorkspacePath = session.projectPath
        selectedSessionID = session.id
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            session.isRunning = false
            self.objectWillChange.send()
        }
        return session
    }

    func selectWorkspace(_ path: String) {
        selectedWorkspacePath = path
        if let selected = sessions(in: path).first(where: { $0.id == selectedSessionID }) {
            selectedSessionID = selected.id
        } else if let first = sessions(in: path).first {
            selectedSessionID = first.id
        }
    }

    func focus(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        selectedWorkspacePath = session.projectPath
        selectedSessionID = id
        NSApp.activate(ignoringOtherApps: true)
    }

    func quit(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let path = sessions[index].projectPath
        sessions[index].terminate()
        sessions.remove(at: index)
        if selectedSessionID == id {
            let remaining = sessions(in: path)
            selectedSessionID = remaining.last?.id ?? sessions.last?.id
            selectedWorkspacePath = selectedSession?.projectPath
        }
        if sessions(in: path).isEmpty, selectedWorkspacePath == path {
            selectedWorkspacePath = workspaces.first?.path
        }
    }

    func sendText(_ id: UUID, text: String) {
        sessions.first { $0.id == id }?.write(text)
    }

    func infos() -> [SessionInfo] {
        sessions.map(\.info)
    }

    func toggleCollapsed(_ path: String) {
        if collapsedWorkspaceIDs.contains(path) {
            collapsedWorkspaceIDs.remove(path)
        } else {
            collapsedWorkspaceIDs.insert(path)
        }
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Parent folder name, e.g. `/Projects/subsets/subsets_api` → `subsets`.
    private static func groupName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" || parent == "Projects" || parent.hasPrefix("Users") {
            return url.lastPathComponent
        }
        return parent
    }
}

@MainActor
final class TerminalSession: Identifiable, ObservableObject {
    let id: UUID
    let title: String
    let projectName: String
    let projectPath: String
    let tool: String
    let commandLine: String
    let initialPrompt: String

    @Published var isRunning = false
    @Published var statusLine: String = "Running"

    /// Raw PTY bytes for the emulator view. Replay buffered output when the view attaches.
    private(set) var pendingOutput = Data()
    var onData: ((Data) -> Void)?

    private let pty = PTYProcess()
    var onExit: (() -> Void)?

    var info: SessionInfo {
        SessionInfo(
            id: id,
            title: title,
            projectName: projectName,
            projectPath: projectPath,
            tool: tool,
            pid: pty.childPID == 0 ? nil : pty.childPID,
            isRunning: isRunning
        )
    }

    var toolLabel: String {
        switch tool {
        case "claudeCode": return "Claude Code"
        case "codexCLI": return "Codex"
        case "cursorCLI": return "Cursor Agent"
        case "grokAgent": return "Grok Agent"
        case "openCode": return "OpenCode"
        default: return tool
        }
    }

    init(request: CreateSessionRequest) {
        self.id = request.sessionID
        self.title = request.title
        self.projectName = request.projectName
        self.projectPath = request.projectPath
        self.tool = request.tool
        self.commandLine = request.command
        self.initialPrompt = request.prompt
    }

    func start() throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = """
        cd \(shellEscape(projectPath)) || exit 1
        exec \(commandLine)
        """
        try pty.start(
            command: shell,
            arguments: ["-lc", script],
            workingDirectory: projectPath
        )
        isRunning = true
        statusLine = "\(toolLabel) running"

        pty.onOutput = { [weak self] data in
            guard let self else { return }
            if let onData {
                onData(data)
            } else {
                pendingOutput.append(data)
            }
        }
        pty.onExit = { [weak self] _ in
            self?.isRunning = false
            self?.statusLine = "Exited"
            self?.onExit?()
        }
    }

    /// Drain any buffered PTY output into the attached emulator.
    func attachOutputHandler(_ handler: @escaping (Data) -> Void) {
        onData = handler
        if !pendingOutput.isEmpty {
            let buffered = pendingOutput
            pendingOutput = Data()
            handler(buffered)
        }
    }

    func detachOutputHandler() {
        onData = nil
    }

    func write(_ text: String) {
        pty.write(text)
    }

    func write(bytes: [UInt8]) {
        pty.write(Data(bytes))
    }

    func resize(cols: UInt16, rows: UInt16) {
        pty.resize(cols: cols, rows: rows)
    }

    func terminate() {
        pty.terminate()
        isRunning = false
        statusLine = "Exited"
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
