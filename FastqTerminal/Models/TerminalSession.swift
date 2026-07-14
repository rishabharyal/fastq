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
        // Don't fork until the terminal view reports a real size — TUIs
        // (Cursor Agent, Claude, etc.) layout incorrectly if born at 40×120.
        session.arm()
        sessions.append(session)
        collapsedWorkspaceIDs.remove(session.projectPath)
        selectedWorkspacePath = session.projectPath
        selectedSessionID = session.id
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            session.isRunning = false
            self.objectWillChange.send()
            // Manual tabs close with their shell, like every terminal app.
            // Agent tabs stay open so the final output remains readable.
            if session.isShell {
                self.quit(session.id)
            }
        }
        return session
    }

    /// Manual terminal tab: interactive login shell in the given directory
    /// (defaults to the selected workspace, then home).
    @discardableResult
    func createShellSession(at path: String? = nil) -> TerminalSession? {
        let targetPath = path
            ?? selectedSession?.projectPath
            ?? selectedWorkspacePath
            ?? NSHomeDirectory()
        let name = URL(fileURLWithPath: targetPath).lastPathComponent
        let request = CreateSessionRequest(
            title: "Terminal",
            projectName: name.isEmpty ? "Home" : name,
            projectPath: targetPath,
            command: "",
            prompt: "",
            tool: TerminalSession.shellTool
        )
        return try? create(from: request)
    }

    /// Select the nth tab overall (Cmd+1…9).
    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        select(sessions[index].id)
    }

    func selectWorkspace(_ path: String) {
        selectedWorkspacePath = path
        collapsedWorkspaceIDs.remove(path)
        if let selected = sessions(in: path).first(where: { $0.id == selectedSessionID }) {
            selectedSessionID = selected.id
        } else if let first = sessions(in: path).first {
            selectedSessionID = first.id
        }
    }

    func focus(_ id: UUID) {
        select(id)
        // Don't activate here — IPC showMainWindow owns presentation so we
        // don't fight SwiftUI into opening a second window.
    }

    /// Switch tab/workspace without stealing app focus (launcher ↑/↓).
    func select(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        selectedWorkspacePath = session.projectPath
        collapsedWorkspaceIDs.remove(session.projectPath)
        selectedSessionID = id
    }

    /// Cycle the active tab. Positive delta = next, negative = previous.
    @discardableResult
    func cycle(by delta: Int) -> UUID? {
        guard !sessions.isEmpty else { return nil }
        let ordered = sessions
        let currentIndex = ordered.firstIndex(where: { $0.id == selectedSessionID }) ?? 0
        let count = ordered.count
        let nextIndex = ((currentIndex + delta) % count + count) % count
        let next = ordered[nextIndex]
        select(next.id)
        return next.id
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
        if sessions.isEmpty {
            onSessionsBecameEmpty?()
        }
    }

    var onSessionsBecameEmpty: (() -> Void)?

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
    static let shellTool = "shell"

    let id: UUID
    let projectName: String
    let projectPath: String
    let tool: String
    let commandLine: String
    let initialPrompt: String

    @Published private(set) var title: String
    @Published var isRunning = false
    @Published var statusLine: String = "Starting…"

    var isShell: Bool { tool == Self.shellTool }

    /// Raw PTY bytes for the emulator view. Replay buffered output when the view attaches.
    private(set) var pendingOutput = Data()
    var onData: ((Data) -> Void)?

    private let pty = PTYProcess()
    /// For the Ghostty IO bridge: captured on the main actor, written from IO threads.
    var ptyHandle: PTYProcess { pty }
    private var didLaunch = false
    private var launchFallbackWork: DispatchWorkItem?
    private var resizeDebounceWork: DispatchWorkItem?
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
        case Self.shellTool: return "Terminal"
        default: return tool
        }
    }

    /// OSC 0/2 window title from the running program. Shell tabs adopt it as
    /// their sidebar title; agent tabs keep the prompt title and only update
    /// the status line.
    func applyTerminalTitle(_ newTitle: String) {
        statusLine = newTitle
        if isShell {
            title = newTitle
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

    /// Wire the session and wait for the first real terminal size before forking.
    func arm() {
        statusLine = "Starting \(toolLabel)…"
        let work = DispatchWorkItem { [weak self] in
            // Fallback if the view never reports a size (rare). Ghostty needs
            // a beat to create the surface and report its first real grid, so
            // give it room — forking early at a guessed size makes TUIs lay
            // out for the wrong terminal.
            self?.launchIfNeeded(cols: 120, rows: 36)
        }
        launchFallbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func launchIfNeeded(cols: UInt16, rows: UInt16) {
        if didLaunch {
            pty.resize(cols: cols, rows: rows)
            return
        }
        didLaunch = true
        launchFallbackWork?.cancel()
        launchFallbackWork = nil

        do {
            try launch(cols: cols, rows: rows)
        } catch {
            isRunning = false
            statusLine = "Failed to start"
            didLaunch = false
        }
    }

    private func launch(cols: UInt16, rows: UInt16) throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if isShell {
            // Manual tab: interactive login shell, like Terminal.app.
            try pty.start(
                command: shell,
                arguments: ["-l"],
                workingDirectory: projectPath,
                cols: cols,
                rows: rows
            )
        } else {
            // Agent tab: non-login shell — faster, fewer profile side-effects
            // that break TUIs.
            let script = """
            cd \(shellEscape(projectPath)) || exit 1
            exec \(commandLine)
            """
            try pty.start(
                command: shell,
                arguments: ["-c", script],
                workingDirectory: projectPath,
                cols: cols,
                rows: rows
            )
        }
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

        // Codex (and similar) boot a full TUI first; type the prompt afterward.
        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            let delay: TimeInterval = tool == "codexCLI" ? 0.55 : 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning else { return }
                self.pty.write(prompt + "\n")
            }
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
        // First real size forks the PTY immediately.
        guard didLaunch else {
            launchIfNeeded(cols: cols, rows: rows)
            return
        }
        // After launch, trail-debounce: the sidebar animation emits a burst of
        // grid sizes; the child should get one SIGWINCH at the settled size so
        // TUIs reflow exactly once instead of scrambling mid-animation.
        resizeDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.launchIfNeeded(cols: cols, rows: rows)
        }
        resizeDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func terminate() {
        resizeDebounceWork?.cancel()
        resizeDebounceWork = nil
        launchFallbackWork?.cancel()
        launchFallbackWork = nil
        pty.terminate()
        isRunning = false
        statusLine = "Exited"
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
