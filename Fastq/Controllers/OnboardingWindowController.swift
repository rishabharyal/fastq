import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings
    private let onOpenLauncher: () -> Void

    init(settings: AppSettings, onOpenLauncher: @escaping () -> Void) {
        self.settings = settings
        self.onOpenLauncher = onOpenLauncher
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show() {
        if let window, window.isVisible {
            positionNearTopCenter(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = OnboardingView(
            settings: settings,
            onFinish: { [weak self] in
                self?.close()
            },
            onOpenLauncher: { [weak self] in
                self?.onOpenLauncher()
            }
        )

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Fastq"
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        window.contentViewController = hosting
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.hasShadow = true
        positionNearTopCenter(window)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        // Never soft-complete — only the Ready CTA marks onboarding done.
        window = nil
    }

    /// Horizontally centered, tucked just under the menu bar.
    private func positionNearTopCenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let topGap: CGFloat = 36
        let y = visible.maxY - size.height - topGap
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
