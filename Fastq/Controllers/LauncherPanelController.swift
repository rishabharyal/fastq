import AppKit
import SwiftUI

@MainActor
final class LauncherPanelController: NSObject, ObservableObject {
    @Published var isVisible = false

    private var panel: KeyablePanel?
    private var escapeMonitor: Any?
    private var sizeObserver: NSObjectProtocol?
    private let settings: AppSettings
    private let sessions: SessionStore
    private lazy var launcher = AgentLauncher(settings: settings, sessions: sessions)
    var onOpenOnboarding: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenAccountSettings: (() -> Void)?
    var onOpenBoards: (() -> Void)?

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
        isVisible = true
        LauncherKeyRouter.shared.isLauncherVisible = true
        // Focus the prompt after the panel is key (don't steal first responder to contentView).
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .fastqFocusLauncherPrompt, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .fastqFocusLauncherPrompt, object: nil)
        }
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

    /// Esc: pop UI layers in order — control focus, mention popup, picker,
    /// session preview, panel.
    func handleEscape() {
        if LauncherKeyRouter.shared.clearControlFocus?() == true {
            return
        }
        if LauncherKeyRouter.shared.isMentionPopupOpen {
            LauncherKeyRouter.shared.closeMentionPopup?()
            return
        }
        if LauncherKeyRouter.shared.isProjectPickerOpen {
            LauncherKeyRouter.shared.closePicker?()
            return
        }
        if LauncherKeyRouter.shared.isSessionPreviewOpen {
            LauncherKeyRouter.shared.closeSessionPreview?()
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

    /// ⌘T: open a shell in the launcher terminal preview (not Fastq Terminal.app).
    func openTerminal() {
        NotificationCenter.default.post(name: .fastqOpenShellPreview, object: nil)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard LauncherKeyRouter.shared.isLauncherVisible else { return event }
            // Only own keys typed in the launcher panel itself — standalone
            // windows (task composer, settings) handle their own Esc/⌘keys.
            guard event.window === self?.panel else { return event }
            if event.keyCode == 53 { // Esc
                DispatchQueue.main.async {
                    self?.handleEscape()
                }
                return nil // swallow so TextField can't keep Esc
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command, event.charactersIgnoringModifiers == "t" {
                // Inside an open terminal preview — swallow, don't spawn another.
                if LauncherKeyRouter.shared.isSessionPreviewOpen {
                    return nil
                }
                DispatchQueue.main.async {
                    self?.openTerminal()
                }
                return nil
            }
            if mods == .command, event.charactersIgnoringModifiers == "," {
                DispatchQueue.main.async {
                    self?.openSettings()
                }
                return nil
            }
            return event
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
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: LauncherMetrics.panelWidth,
                height: LauncherMetrics.panelExpandedHeight
            ),
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
        panel.animationBehavior = .none
        panel.onEscape = { [weak self] in
            self?.handleEscape()
        }

        let root = LauncherView(
            settings: settings,
            sessions: sessions,
            auth: FastplayAuthStore.shared,
            launcher: launcher,
            onDismiss: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onOpenAccountSettings: { [weak self] in self?.onOpenAccountSettings?() },
            onOpenBoards: { [weak self] in self?.onOpenBoards?() },
            onOpenOnboarding: onOpenOnboarding,
            onOpenTerminal: { [weak self] in self?.openTerminal() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // The SwiftUI content collapses when there's nothing to list —
        // track its size and keep the panel hugging it (top edge fixed).
        sizeObserver = NotificationCenter.default.addObserver(
            forName: .fastqLauncherPanelSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let height = note.userInfo?["height"] as? CGFloat,
                  let width = note.userInfo?["width"] as? CGFloat else { return }
            Task { @MainActor in
                self?.resizePanel(to: NSSize(width: width, height: height))
            }
        }

        self.panel = panel
    }

    private func resizePanel(to size: NSSize) {
        guard let panel else { return }
        let current = panel.frame
        guard abs(current.height - size.height) > 1 || abs(current.width - size.width) > 1 else { return }
        // Always re-center on the active screen so growth blooms on all sides.
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? current
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2
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
