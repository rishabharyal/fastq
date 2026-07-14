import Foundation
import Combine
import AppKit

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

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
        sessions.removeAll { $0.id == id }
    }

    func removeAllHostedInTerminal() {
        sessions.removeAll { $0.hostedInFastqTerminal }
    }

    func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    private func pruneDeadSessions() {
        let terminalAlive = FastqTerminalClient.shared.isTerminalProcessRunning()

        // Cmd+Q (or crash) of Fastq Terminal kills every hosted tab — drop them here.
        if !terminalAlive {
            let hadHosted = sessions.contains(where: \.hostedInFastqTerminal)
            sessions.removeAll(where: \.hostedInFastqTerminal)
            if hadHosted {
                objectWillChange.send()
            }
        }

        sessions.removeAll { session in
            if session.hostedInFastqTerminal {
                // Still hosted only while Terminal process exists; finer sync below.
                return false
            }
            guard session.status != .launching else { return false }
            guard let pid = session.processIdentifier else {
                return session.status == .exited
            }
            return !processIsAlive(pid)
        }

        for index in sessions.indices {
            if sessions[index].hostedInFastqTerminal { continue }
            if let pid = sessions[index].processIdentifier, !processIsAlive(pid) {
                sessions[index].status = .exited
            } else if sessions[index].status == .launching,
                      let pid = sessions[index].processIdentifier,
                      processIsAlive(pid) {
                sessions[index].status = .running
            }
        }

        sessions.removeAll { !$0.hostedInFastqTerminal && $0.status == .exited }

        // If Terminal is up, drop launcher rows whose tabs no longer exist.
        if terminalAlive, sessions.contains(where: \.hostedInFastqTerminal) {
            Task { await syncHostedSessionsWithTerminal() }
        }
    }

    private func syncHostedSessionsWithTerminal() async {
        guard FastqTerminalClient.shared.isTerminalAlive() else {
            sessions.removeAll(where: \.hostedInFastqTerminal)
            return
        }
        do {
            let remote = try await FastqTerminalClient.shared.listSessions()
            let liveIDs = Set(remote.map(\.id))
            sessions.removeAll { session in
                session.hostedInFastqTerminal && !liveIDs.contains(session.id)
            }
        } catch {
            // Socket flake — don't wipe sessions on a transient error.
        }
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
