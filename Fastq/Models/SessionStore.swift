import Foundation
import Combine
import AppKit

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var pollTimer: Timer?

    func startMonitoring() {
        stopMonitoring()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
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

    func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    private func pruneDeadSessions() {
        sessions.removeAll { session in
            guard session.status != .launching else { return false }
            guard let pid = session.processIdentifier else {
                return session.status == .exited
            }
            return !processIsAlive(pid)
        }

        for index in sessions.indices {
            if let pid = sessions[index].processIdentifier, !processIsAlive(pid) {
                sessions[index].status = .exited
            } else if sessions[index].status == .launching,
                      let pid = sessions[index].processIdentifier,
                      processIsAlive(pid) {
                sessions[index].status = .running
            }
        }

        sessions.removeAll { $0.status == .exited }
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
