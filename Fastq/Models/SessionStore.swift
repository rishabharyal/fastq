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
