import Foundation
import Combine
import AppKit

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// Owns local Ghostty PTYs — same UUID as AgentSession.id.
    let terminals = TerminalSessionStore()

    private var pollTimer: Timer?

    func startMonitoring() {
        stopMonitoring()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneDeadSessions()
            }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func add(_ session: AgentSession) {
        sessions.insert(session, at: 0)
    }

    func update(_ session: AgentSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
    }

    func remove(_ id: UUID) {
        terminals.quit(id)
        sessions.removeAll { $0.id == id }
    }

    func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// Sessions started for a Fastplay project, newest first. Matches the
    /// durable link when present; pre-link sessions (and ⌘T shells) are
    /// matched by the folder linked to that project.
    func sessions(forProjectID projectID: String, projectPath: String? = nil) -> [AgentSession] {
        let path = projectPath.map { Self.normalizedPath($0) }
        return sessions.filter { session in
            if let linked = session.taskLink?.projectID { return linked == projectID }
            guard let path else { return false }
            return Self.normalizedPath(session.projectPath) == path
        }
    }

    /// Sessions whose working directory is this folder, newest first.
    func sessions(forProjectPath projectPath: String) -> [AgentSession] {
        let path = Self.normalizedPath(projectPath)
        return sessions.filter { Self.normalizedPath($0.projectPath) == path }
    }

    /// Sessions started for a Fastplay workspace, newest first.
    func sessions(forWorkspaceID workspaceID: String) -> [AgentSession] {
        sessions.filter { $0.taskLink?.workspaceID == workspaceID }
    }

    /// Sessions started for a single task, newest first.
    func sessions(forTaskID taskID: String) -> [AgentSession] {
        sessions.filter { $0.taskLink?.taskID == taskID }
    }

    /// Trailing slashes and `~` shouldn't split a project's sessions.
    private static func normalizedPath(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        return expanded
    }

    func terminal(id: UUID) -> TerminalSession? {
        terminals.sessions.first { $0.id == id }
    }

    /// Upsert launcher row for a local terminal session (e.g. ⌘T shell).
    func upsertFromTerminal(_ terminal: TerminalSession) {
        let tool = AgentToolKind(rawValue: terminal.tool) ?? .shell
        if let index = sessions.firstIndex(where: { $0.id == terminal.id }) {
            sessions[index].processIdentifier = terminal.childPID
            sessions[index].status = terminal.isRunning ? .running : .exited
            return
        }
        let session = AgentSession(
            id: terminal.id,
            tool: tool,
            projectName: terminal.projectName,
            projectPath: terminal.projectPath,
            promptPreview: terminal.title == "Terminal" ? "" : terminal.title,
            model: .auto,
            startedAt: Date(),
            processIdentifier: terminal.childPID,
            terminalWindowID: nil,
            status: terminal.isRunning ? .running : .exited
        )
        sessions.insert(session, at: 0)
    }

    private func pruneDeadSessions() {
        let liveTerminalIDs = Set(terminals.sessions.map(\.id))
        let liveChatIDs = Set(AgentChatStore.shared.sessions.map(\.id))
        sessions.removeAll { session in
            session.isChat ? !liveChatIDs.contains(session.id) : !liveTerminalIDs.contains(session.id)
        }

        for index in sessions.indices {
            if sessions[index].isChat {
                guard let chat = AgentChatStore.shared.session(id: sessions[index].id) else { continue }
                // Reconciliation only refreshes run state — keep the task
                // link, and adopt the chat's if this row never had one.
                if sessions[index].taskLink == nil, let link = chat.taskLink {
                    sessions[index].taskLink = link
                }
                switch chat.phase {
                case .running:
                    sessions[index].status = .running
                    sessions[index].activity = .working
                case .waitingForUser:
                    sessions[index].status = .running
                    sessions[index].activity = .waiting
                case .done, .failed, .idle:
                    sessions[index].status = .running
                    sessions[index].activity = .done
                }
                continue
            }
            guard let term = terminal(id: sessions[index].id) else { continue }
            sessions[index].processIdentifier = term.childPID
            sessions[index].status = term.isRunning ? .running : .exited
        }
    }
}
