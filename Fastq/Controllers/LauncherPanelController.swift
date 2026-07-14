import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController: NSObject, ObservableObject {
    @Published var isVisible = false

    private var panel: KeyablePanel?
    private var escapeMonitor: Any?
    private let settings: AppSettings
    private let sessions: SessionStore
    private lazy var launcher = AgentLauncher(settings: settings, sessions: sessions)
    var onOpenOnboarding: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(settings: AppSettings, sessions: SessionStore) {
        self.settings = settings
        self.sessions = sessions
        super.init()
    }

    func setup() {
        sessions.startMonitoring()
        HotKeyManager.shared.onHotKey = { [weak self] in
            self?.toggle()
        }
        HotKeyManager.shared.register(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers
        )
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        ensurePanel()
        guard let panel else { return }
        positionPanel(panel)
        wireEscapeRouting()
        installEscapeMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        isVisible = true
        LauncherKeyRouter.shared.isLauncherVisible = true
    }

    func hide() {
        removeEscapeMonitor()
        LauncherKeyRouter.shared.isProjectPickerOpen = false
        LauncherKeyRouter.shared.isLauncherVisible = false
        panel?.orderOut(nil)
        isVisible = false
    }

    func openSettings() {
        hide()
        onOpenSettings?()
    }

    /// Esc: close project picker if open, otherwise hide the launcher.
    func handleEscape() {
        if LauncherKeyRouter.shared.isProjectPickerOpen {
            LauncherKeyRouter.shared.closePicker?()
            return
        }
        hide()
    }

    var agentLauncher: AgentLauncher { launcher }

    private func wireEscapeRouting() {
        LauncherKeyRouter.shared.onDismissLauncher = { [weak self] in
            self?.hide()
        }
        LauncherKeyRouter.shared.onEscape = { [weak self] in
            self?.handleEscape()
        }
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            guard LauncherKeyRouter.shared.isLauncherVisible else { return event }
            DispatchQueue.main.async {
                self?.handleEscape()
            }
            return nil // swallow so TextField can't keep Esc
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { [weak self] in
            self?.handleEscape()
        }

        let root = LauncherView(
            settings: settings,
            sessions: sessions,
            launcher: launcher,
            onDismiss: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenOnboarding: onOpenOnboarding
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Panel that accepts Esc via AppKit's cancelOperation responder chain.
private final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
