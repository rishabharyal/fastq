import AppKit
import SwiftUI

/// Dedicated settings window — SwiftUI `Settings` scenes are unreliable for
/// menu-bar accessory apps (won't reopen after close, can appear on launch).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings
    private let auth: FastplayAuthStore
    private let onReplayOnboarding: () -> Void
    private var preferredTab: SettingsView.SettingsTab = .projects

    init(
        settings: AppSettings,
        auth: FastplayAuthStore = .shared,
        onReplayOnboarding: @escaping () -> Void
    ) {
        self.settings = settings
        self.auth = auth
        self.onReplayOnboarding = onReplayOnboarding
        super.init()
    }

    func show(tab: SettingsView.SettingsTab = .projects) {
        preferredTab = tab
        if let window {
            // Rebuild content so the preferred tab applies.
            window.contentViewController = makeHostingController()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fastq Settings"
        window.contentViewController = makeHostingController()
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

    private func makeHostingController() -> NSHostingController<SettingsView> {
        let root = SettingsView(
            settings: settings,
            auth: auth,
            initialTab: preferredTab
        ) { [weak self] in
            self?.close()
            self?.onReplayOnboarding()
        }
        return NSHostingController(rootView: root)
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
