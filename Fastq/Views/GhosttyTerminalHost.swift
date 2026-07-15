import SwiftUI
import AppKit
import GhosttyTerminal

/// Hosts one Ghostty surface per session, bridged to a local PTY.
///
/// Important: `InMemoryTerminalSession.receive` drops bytes until a surface is
/// attached. Journal replay must wait for that surface, otherwise reopening a
/// task shows a blank terminal.
struct GhosttyTerminalHost: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = FastqSurfaceView(frame: .zero)
        view.delegate = context.coordinator
        view.controller = FastqTerminalEngine.controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(context.coordinator.ghosttySession),
            workingDirectory: session.projectPath
        )
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        let session: TerminalSession
        let ghosttySession: InMemoryTerminalSession
        weak var view: TerminalView?
        private var isActive = false
        private var actionObserver: NSObjectProtocol?
        private var outputToken: UUID?
        private var surfacePollWork: DispatchWorkItem?

        init(session: TerminalSession) {
            self.session = session

            let pty = session.ptyHandle
            ghosttySession = InMemoryTerminalSession(
                write: { data in
                    pty.write(data)
                },
                resize: { [weak session] viewport in
                    let cols = viewport.columns
                    let rows = viewport.rows
                    let cellW = Double(viewport.cellWidthPixels)
                    let cellH = Double(viewport.cellHeightPixels)
                    Task { @MainActor in
                        session?.updateGridMetrics(
                            cols: cols,
                            rows: rows,
                            cellWidth: cellW > 0 ? cellW : nil,
                            cellHeight: cellH > 0 ? cellH : nil
                        )
                        session?.resize(cols: cols, rows: rows)
                    }
                }
            )
            super.init()

            actionObserver = NotificationCenter.default.addObserver(
                forName: .fastqTerminalBindingAction,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let action = note.object as? String else { return }
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    self.view?.performBindingAction(action)
                }
            }
        }

        func attach(_ view: TerminalView) {
            self.view = view
            session.ghosttyMirror = ghosttySession
            beginOutputWhenSurfaceReady()
        }

        func setActive(_ active: Bool) {
            isActive = active
            guard let view else { return }
            view.setSurfaceVisible(active)
            if active {
                // Surface often appears on first activation / layout.
                beginOutputWhenSurfaceReady()
                DispatchQueue.main.async { [weak view] in
                    guard let view, let window = view.window else { return }
                    window.makeFirstResponder(view)
                }
            }
        }

        func detach() {
            surfacePollWork?.cancel()
            surfacePollWork = nil
            if let outputToken {
                session.detachOutputHandler(outputToken)
            }
            outputToken = nil
            session.ghosttyMirror = nil
            if let actionObserver {
                NotificationCenter.default.removeObserver(actionObserver)
            }
            actionObserver = nil
        }

        /// Wait until Ghostty attaches a surface, then subscribe (and replay
        /// the PTY journal). Early `receive` calls are silently dropped.
        private func beginOutputWhenSurfaceReady(attempt: Int = 0) {
            surfacePollWork?.cancel()
            if outputToken != nil { return }

            if ghosttySession.readViewportText() != nil {
                subscribeOutput()
                return
            }

            // Also try after the view is in a window and has a non-zero size —
            // that is when Ghostty typically creates the surface.
            if let view, view.window != nil, view.bounds.width > 1, view.bounds.height > 1,
               attempt >= 2 {
                // Keep polling a bit longer; surface may still be nil briefly.
            }

            guard attempt < 80 else {
                // Last resort: subscribe so live output still flows.
                subscribeOutput()
                return
            }

            let work = DispatchWorkItem { [weak self] in
                self?.beginOutputWhenSurfaceReady(attempt: attempt + 1)
            }
            surfacePollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        private func subscribeOutput() {
            guard outputToken == nil else { return }
            let ghosttySession = ghosttySession
            outputToken = session.attachOutputHandler { data in
                ghosttySession.receive(data)
            }
        }
    }
}

// MARK: - Surface delegate

extension GhosttyTerminalHost.Coordinator:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceOpenURLDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        guard !title.isEmpty else { return }
        session.applyTerminalTitle(title)
    }

    func terminalDidRingBell() {
        NSSound.beep()
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        if let parsed = URL(string: url) {
            NSWorkspace.shared.open(parsed)
        }
    }
}
