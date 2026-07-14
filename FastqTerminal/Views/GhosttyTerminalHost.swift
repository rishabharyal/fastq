import SwiftUI
import AppKit
import GhosttyTerminal

// MARK: - Shared engine

/// One Ghostty app + config shared by every surface in the process.
@MainActor
enum FastqTerminalEngine {
    static let controller: TerminalController = {
        TerminalController(theme: fastqTheme) { builder in
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(false)
            builder.withFontSize(13)
            builder.withFontThicken(true)
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
            builder.withCustom("mouse-hide-while-typing", "true")

            // Terminal-owned shortcuts. These fire before the menu bar when the
            // surface is focused; menu items with the same equivalents cover the
            // sidebar-focused case.
            for bind in [
                "super+c=copy_to_clipboard",
                "super+v=paste_from_clipboard",
                "super+a=select_all",
                "super+k=clear_screen",
                "super+equal=increase_font_size:1",
                "super+plus=increase_font_size:1",
                "super+minus=decrease_font_size:1",
                "super+zero=reset_font_size",
                // Line editing, Terminal.app/iTerm conventions.
                "alt+left=esc:b",
                "alt+right=esc:f",
                "super+left=text:\\x01",
                "super+right=text:\\x05",
                "super+backspace=text:\\x15",
                // Scrollback navigation.
                "super+home=scroll_to_top",
                "super+end=scroll_to_bottom",
                "shift+page_up=scroll_page_up",
                "shift+page_down=scroll_page_down",
                "super+up=jump_to_prompt:-1",
                "super+down=jump_to_prompt:1",
            ] {
                builder.withCustom("keybind", bind)
            }
        }
    }()

    /// Afterglow palette with Fastq's window background + accent cursor.
    private static var fastqTheme: TerminalTheme {
        let dark = TerminalConfiguration { builder in
            builder.withBackground("121214")
            builder.withForeground("EBEBEB")
            builder.withCursorColor("73B3FF")
            builder.withSelectionBackground("2C3A4E")
            builder.withSelectionForeground("EBEBEB")
            builder.withPalette(0, color: "#1B1B1E")
            builder.withPalette(1, color: "#F06C75")
            builder.withPalette(2, color: "#8CC265")
            builder.withPalette(3, color: "#E5C07B")
            builder.withPalette(4, color: "#61AFEF")
            builder.withPalette(5, color: "#C678DD")
            builder.withPalette(6, color: "#56B6C2")
            builder.withPalette(7, color: "#D7DAE0")
            builder.withPalette(8, color: "#5F6672")
            builder.withPalette(9, color: "#FF7B86")
            builder.withPalette(10, color: "#A5E075")
            builder.withPalette(11, color: "#F0C674")
            builder.withPalette(12, color: "#73B3FF")
            builder.withPalette(13, color: "#D58AEC")
            builder.withPalette(14, color: "#66D9E8")
            builder.withPalette(15, color: "#FFFFFF")
        }
        return TerminalTheme(light: dark, dark: dark)
    }
}

extension Notification.Name {
    /// Posted by menu items; the active session's host performs the Ghostty
    /// binding action (object is the action string, e.g. "clear_screen").
    static let fastqTerminalBindingAction = Notification.Name("fastq.terminalBindingAction")
}

// MARK: - Per-session host

/// Hosts one Ghostty surface per session, bridged to the session's PTY.
/// The session model (PTY, IPC, store) is unchanged — Ghostty only replaces
/// the emulator/renderer layer.
struct GhosttyTerminalHost: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
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

        init(session: TerminalSession) {
            self.session = session

            // PTY handle captured once on the main actor; the callbacks below
            // run on Ghostty's IO threads and only touch the (thread-safe) fd.
            let pty = session.ptyHandle
            ghosttySession = InMemoryTerminalSession(
                write: { data in
                    // Terminal-generated bytes (keystrokes, replies) → PTY.
                    pty.write(data)
                },
                resize: { [weak session] viewport in
                    let cols = viewport.columns
                    let rows = viewport.rows
                    Task { @MainActor in
                        // First real size also triggers the PTY fork (arm()).
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
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    self.view?.performBindingAction(action)
                }
            }
        }

        func attach(_ view: TerminalView) {
            self.view = view
            let ghosttySession = ghosttySession
            session.attachOutputHandler { data in
                // PTY output → Ghostty (parses on its own serial queue).
                ghosttySession.receive(data)
            }
        }

        func setActive(_ active: Bool) {
            isActive = active
            guard let view else { return }
            // Pause rendering for hidden tabs; state/scrollback keeps updating.
            view.setSurfaceVisible(active)
            if active {
                DispatchQueue.main.async { [weak view] in
                    guard let view, let window = view.window else { return }
                    window.makeFirstResponder(view)
                }
            }
        }

        func detach() {
            session.detachOutputHandler()
            if let actionObserver {
                NotificationCenter.default.removeObserver(actionObserver)
            }
            actionObserver = nil
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
