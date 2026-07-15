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
    /// User-arranged project order (drag to reorder). Paths not listed here
    /// (new projects) append after in first-seen order.
    @Published private(set) var workspaceOrder: [String] = []

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var workspaces: [TerminalWorkspace] {
        var seen: [String: TerminalWorkspace] = [:]
        var encounter: [String] = []
        for session in sessions {
            if seen[session.projectPath] == nil {
                seen[session.projectPath] = TerminalWorkspace(
                    name: session.projectName,
                    path: session.projectPath,
                    abbreviatedPath: Self.abbreviate(session.projectPath),
                    groupName: Self.groupName(for: session.projectPath)
                )
                encounter.append(session.projectPath)
            }
        }
        let pinned = workspaceOrder.filter { seen[$0] != nil }
        let rest = encounter.filter { !workspaceOrder.contains($0) }
        return (pinned + rest).compactMap { seen[$0] }
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
            // Shell tabs (manual or fallback) close with their process, like
            // every terminal app. Agent tabs drop into a shell in the same
            // tab so the workflow continues where the agent left off.
            if session.closesOnExit {
                self.quit(session.id)
            } else {
                session.relaunchAsShell()
                self.objectWillChange.send()
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
        AgentActivityMirror.remove(sessionID: id)
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

    /// ⇧⌘W: close every tab in the current project.
    func quitAllInSelectedWorkspace() {
        guard let path = selectedSession?.projectPath ?? selectedWorkspacePath else { return }
        for session in sessions(in: path) {
            quit(session.id)
        }
    }

    /// Drag-reorder: move a project so it takes the target project's slot.
    func moveWorkspace(_ path: String, to targetPath: String) {
        var order = workspaces.map(\.path)
        guard let from = order.firstIndex(of: path),
              let to = order.firstIndex(of: targetPath),
              from != to
        else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        workspaceOrder = order
    }

    /// Drag-reorder: move a tab onto another tab's slot within the same
    /// project (a tab's PTY is anchored to its folder, so no cross-project
    /// moves). Reorders the flat array, so Cmd+1…9 follows the new order.
    func moveSession(_ id: UUID, to targetID: UUID) {
        guard let from = sessions.firstIndex(where: { $0.id == id }),
              let to = sessions.firstIndex(where: { $0.id == targetID }),
              from != to,
              sessions[from].projectPath == sessions[to].projectPath
        else { return }
        sessions.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
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

    /// Agent tab whose process exited and was replaced by a login shell.
    private(set) var isFallbackShell = false
    /// Shell-like tabs close with their process; agent tabs fall back to a shell.
    var closesOnExit: Bool { isShell || isFallbackShell }

    /// Raw PTY bytes for the emulator view; buffers until the view attaches.
    private let output = TerminalOutputBridge()

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
            isRunning: isRunning,
            activity: activity.rawValue
        )
    }

    /// Fine-grained agent turn state (any AI CLI via OSC + PTY heuristics).
    @Published private(set) var activity: AgentActivity = .idle
    /// Throttle PTY heuristic updates so TUIs don't spam SwiftUI.
    private var lastActivityInferAt: Date = .distantPast

    var toolLabel: String {
        if isFallbackShell { return "Terminal" }
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

    private var tracksAgentActivity: Bool {
        !isShell && !isFallbackShell
    }

    /// OSC 0/2 window title from the running program. Shell tabs adopt it as
    /// their sidebar title; agent tabs keep the prompt title and only update
    /// the status line. Canonical `fastq:<activity>` titles win for all agents.
    func applyTerminalTitle(_ newTitle: String) {
        if tracksAgentActivity, let parsed = AgentActivityInterpreter.fromOSCTitle(newTitle) {
            applyActivity(parsed)
            return
        }
        // TUIs spam identical titles; don't churn SwiftUI for no-ops.
        if statusLine != newTitle {
            statusLine = newTitle
        }
        if isShell || isFallbackShell, title != newTitle {
            title = newTitle
        }
    }

    private func applyActivity(_ next: AgentActivity) {
        let changed = activity != next
        if changed {
            activity = next
        }
        let label = next.launcherLabel
        if statusLine != label {
            statusLine = label
        }
        // Always mirror so the launcher picks up the latest state quickly.
        AgentActivityMirror.write(sessionID: id, activity: next)
    }

    private func noteAgentOutput(_ data: Data) {
        guard tracksAgentActivity, isRunning else { return }
        let now = Date()
        // ~8 Hz ceiling — enough for status, cheap for TUIs.
        guard now.timeIntervalSince(lastActivityInferAt) >= 0.12 else { return }
        guard let inferred = AgentActivityInterpreter.fromPTYOutput(data) else { return }
        lastActivityInferAt = now
        applyActivity(inferred)
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
        // Wire callbacks before forking — output starts flowing immediately.
        wirePTYCallbacks()
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
        if tracksAgentActivity {
            applyActivity(.working)
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

    private func wirePTYCallbacks() {
        // Output flows on the PTY read queue straight into the emulator's
        // parse queue — main only hears about lifecycle + activity inference.
        pty.onOutput = { [output, weak self] data in
            output.emit(data)
            DispatchQueue.main.async {
                self?.noteAgentOutput(data)
            }
        }
        pty.onExit = { [weak self] _ in
            self?.isRunning = false
            self?.statusLine = "Exited"
            if self?.tracksAgentActivity == true {
                self?.applyActivity(.done)
            }
            self?.onExit?()
        }
    }

    /// Agent process ended: keep the tab (scrollback intact) and drop into a
    /// login shell in the project folder, like any terminal would.
    func relaunchAsShell() {
        guard !isRunning, !closesOnExit else { return }
        let notice = "\r\n\u{1B}[2m── \(toolLabel) exited · dropping into shell ──\u{1B}[0m\r\n"
        output.emit(Data(notice.utf8))

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let size = pty.size
        wirePTYCallbacks()
        do {
            try pty.start(
                command: shell,
                arguments: ["-l"],
                workingDirectory: projectPath,
                cols: size.cols,
                rows: size.rows
            )
        } catch {
            statusLine = "Failed to start shell"
            return
        }
        isFallbackShell = true
        isRunning = true
        statusLine = "Terminal"
    }

    /// Drain any buffered PTY output into the attached emulator.
    func attachOutputHandler(_ handler: @escaping (Data) -> Void) {
        output.attach(handler)
    }

    func detachOutputHandler() {
        output.detach()
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

/// Thread-safe PTY→emulator hand-off. `emit` is called on the PTY read
/// queue; the attached handler (Ghostty's `receive`) parses on its own
/// serial queue, so terminal output never touches the main thread.
final class TerminalOutputBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    private var pending = Data()

    func emit(_ data: Data) {
        lock.lock()
        guard let handler else {
            pending.append(data)
            lock.unlock()
            return
        }
        lock.unlock()
        handler(data)
    }

    func attach(_ newHandler: @escaping (Data) -> Void) {
        lock.lock()
        handler = newHandler
        let buffered = pending
        pending = Data()
        lock.unlock()
        if !buffered.isEmpty {
            newHandler(buffered)
        }
    }

    func detach() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}
