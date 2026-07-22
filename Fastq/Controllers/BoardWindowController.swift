import AppKit
import SwiftUI

@MainActor
final class BoardWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let auth: FastplayAuthStore
    private let sessions: SessionStore

    init(auth: FastplayAuthStore = .shared, sessions: SessionStore) {
        self.auth = auth
        self.sessions = sessions
        super.init()
    }

    /// True while the board window is on screen — the agent-start handler uses
    /// this to decide whether to keep the board up and open a run tab in it.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = BoardView(auth: auth, sessions: sessions)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fastq Boards"
        window.contentViewController = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FastqBoards")
        window.center()
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
