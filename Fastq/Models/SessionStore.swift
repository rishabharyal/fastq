import Foundation
import Combine
import AppKit
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    private var pollTimer: Timer?
    private var isSyncing = false

    func startMonitoring() {
        stopMonitoring()
        // Sub-second poll so Active Windows status tracks agent activity live.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        // Keep firing while scrolling / tracking loops run.
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
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

    private func tick() {
        // Instant path: activity mirror file written by Terminal on every change.
        applyActivityMirror()
        pruneDeadSessions()
        if FastqTerminalClient.shared.isTerminalProcessRunning(),
           sessions.contains(where: \.hostedInFastqTerminal) {
            Task { await syncHostedSessionsWithTerminal() }
        }
    }

    /// Apply Terminal's activity-state.json without waiting on IPC.
    private func applyActivityMirror() {
        let map = AgentActivityMirror.readAll()
        guard !map.isEmpty else { return }
        var next = sessions
        var changed = false
        for index in next.indices {
            guard next[index].hostedInFastqTerminal else { continue }
            let key = next[index].id.uuidString
            guard let raw = map[key], let activity = AgentActivity(rawValue: raw) else { continue }
            if next[index].activity != activity {
                next[index].activity = activity
                if next[index].status == .launching {
                    next[index].status = .running
                }
                changed = true
            }
        }
        if changed {
            withAnimation(.easeInOut(duration: 0.2)) {
                sessions = next
            }
        }
    }

    private func pruneDeadSessions() {
        let terminalAlive = FastqTerminalClient.shared.isTerminalProcessRunning()

        // Cmd+Q (or crash) of Fastq Terminal kills every hosted tab — drop them here.
        if !terminalAlive {
            let hadHosted = sessions.contains(where: \.hostedInFastqTerminal)
            if hadHosted {
                sessions.removeAll(where: \.hostedInFastqTerminal)
            }
            return
        }

        var next = sessions
        var changed = false

        next.removeAll { session in
            if session.hostedInFastqTerminal { return false }
            guard session.status != .launching else { return false }
            guard let pid = session.processIdentifier else {
                return session.status == .exited
            }
            return !processIsAlive(pid)
        }

        for index in next.indices {
            if next[index].hostedInFastqTerminal { continue }
            if let pid = next[index].processIdentifier, !processIsAlive(pid) {
                if next[index].status != .exited {
                    next[index].status = .exited
                    changed = true
                }
            } else if next[index].status == .launching,
                      let pid = next[index].processIdentifier,
                      processIsAlive(pid) {
                next[index].status = .running
                changed = true
            }
        }

        let withoutExited = next.filter { $0.hostedInFastqTerminal || $0.status != .exited }
        if withoutExited.count != next.count {
            next = withoutExited
            changed = true
        }

        if changed || next != sessions {
            sessions = next
        }
    }

    private func syncHostedSessionsWithTerminal() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        guard FastqTerminalClient.shared.isTerminalAlive() else {
            if sessions.contains(where: \.hostedInFastqTerminal) {
                sessions.removeAll(where: \.hostedInFastqTerminal)
            }
            return
        }
        do {
            let remote = try await FastqTerminalClient.shared.listSessions()
            let liveIDs = Set(remote.map(\.id))
            var next = sessions.filter { session in
                !session.hostedInFastqTerminal || liveIDs.contains(session.id)
            }
            var changed = next.count != sessions.count

            for info in remote {
                guard let index = next.firstIndex(where: { $0.id == info.id }) else { continue }
                var session = next[index]

                if let raw = info.activity, let activity = AgentActivity(rawValue: raw),
                   session.activity != activity {
                    session.activity = activity
                    changed = true
                }
                if let pid = info.pid, session.processIdentifier != pid {
                    session.processIdentifier = pid
                    changed = true
                }
                if info.isRunning, session.status == .launching {
                    session.status = .running
                    changed = true
                }
                if !info.isRunning, session.status == .running {
                    session.status = .exited
                    session.activity = .done
                    changed = true
                }
                next[index] = session
            }

            if changed {
                // Reassign so @Published / SwiftUI always see a new value.
                withAnimation(.easeInOut(duration: 0.22)) {
                    sessions = next
                }
            }
        } catch {
            // Socket flake — don't wipe sessions on a transient error.
        }
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
