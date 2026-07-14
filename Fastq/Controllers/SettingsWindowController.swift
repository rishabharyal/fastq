import AppKit
import SwiftUI

/// Dedicated settings window — SwiftUI `Settings` scenes are unreliable for
/// menu-bar accessory apps (won't reopen after close, can appear on launch).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings
    private let onReplayOnboarding: () -> Void

    init(settings: AppSettings, onReplayOnboarding: @escaping () -> Void) {
        self.settings = settings
        self.onReplayOnboarding = onReplayOnboarding
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = SettingsView(settings: settings) { [weak self] in
            self?.close()
            self?.onReplayOnboarding()
        }
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fastq Settings"
        window.contentViewController = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("FastqSettings")
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the window around so reopen is instant and reliable.
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
