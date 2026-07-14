import SwiftUI
import AppKit

@main
struct FastqTerminalApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Single `Window` (not `WindowGroup`) so hide → show never spawns a second one.
        Window("Fastq Terminal", id: TerminalAppDelegate.mainWindowID) {
            ZStack {
                TerminalRootView(store: appDelegate.store)
                TerminalWindowOpener()
            }
            .background(WindowCloseInterceptor(appDelegate: appDelegate))
            .onAppear {
                appDelegate.ensureRunning()
            }
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") {
                    appDelegate.store.createShellSession()
                    appDelegate.showMainWindow()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Terminal") {
                    if let id = appDelegate.store.selectedSessionID {
                        appDelegate.store.quit(id)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Close All in Project") {
                    appDelegate.store.quitAllInSelectedWorkspace()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .fastqToggleTerminalSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu("Terminal") {
                // With the terminal focused these are consumed by Ghostty's
                // keybinds first; the menu covers sidebar/toolbar focus.
                Button("Clear Screen") {
                    NotificationCenter.default.post(name: .fastqTerminalBindingAction, object: "clear_screen")
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Increase Font Size") {
                    NotificationCenter.default.post(name: .fastqTerminalBindingAction, object: "increase_font_size:1")
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Font Size") {
                    NotificationCenter.default.post(name: .fastqTerminalBindingAction, object: "decrease_font_size:1")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Font Size") {
                    NotificationCenter.default.post(name: .fastqTerminalBindingAction, object: "reset_font_size")
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("Previous Terminal") {
                    appDelegate.store.cycle(by: -1)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Terminal") {
                    appDelegate.store.cycle(by: 1)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Divider()

                ForEach(1..<10) { index in
                    Button("Terminal \(index)") {
                        appDelegate.store.select(index: index - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
        }
    }
}

@MainActor
final class TerminalAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let mainWindowID = "fastq.terminal.main"

    let store = TerminalSessionStore()
    private var ipc: TerminalIPCServer?
    /// Strong retain — `orderOut` must not let us lose the window reference.
    private var retainedMainWindow: NSWindow?
    private var allowDestructiveClose = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        store.onSessionsBecameEmpty = { [weak self] in
            self?.hideMainWindow()
        }
        let server = TerminalIPCServer(store: store)
        server.start()
        ipc = server

        // Ctrl+Tab / Ctrl+Shift+Tab cycle tabs (before the focused terminal
        // sees the event, matching every tabbed macOS app).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, // Tab
                  event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option)
            else { return event }
            let backwards = event.modifierFlags.contains(.shift)
            self?.store.cycle(by: backwards ? -1 : 1)
            return nil
        }

        // App-owned Cmd shortcuts. The Ghostty surface consumes key
        // equivalents (super+t etc.) before the menu bar sees them, so these
        // must intercept ahead of event dispatch to work while typing.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // ⌥⌘← / ⌥⌘→ — prev/next tab, Terminal.app-style.
            if mods == [.command, .option] {
                switch event.keyCode {
                case 123: self.store.cycle(by: -1); return nil // ←
                case 124: self.store.cycle(by: 1); return nil  // →
                default: return event
                }
            }

            if mods == [.command, .shift] {
                switch event.keyCode {
                case 33: self.store.cycle(by: -1); return nil // [
                case 30: self.store.cycle(by: 1); return nil  // ]
                case 13: self.store.quitAllInSelectedWorkspace(); return nil // W
                default: return event
                }
            }

            guard mods == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "t":
                self.store.createShellSession()
                self.showMainWindow()
                return nil
            case "s":
                NotificationCenter.default.post(name: .fastqToggleTerminalSidebar, object: nil)
                return nil
            case "w":
                if let id = self.store.selectedSessionID {
                    self.store.quit(id)
                }
                return nil
            case let digit? where digit.count == 1 && "123456789".contains(digit):
                self.store.select(index: Int(digit)! - 1)
                return nil
            default:
                return event
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                self?.adopt(window)
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.adoptExistingWindows()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipc?.stop()
        for session in store.sessions {
            session.terminate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If we were activated (Dock / launcher) with only a hidden window, reveal it
        // when there are live sessions — mirrors Dock reopen behavior.
        let hasHiddenMain = retainedMainWindow?.isVisible == false
        if hasHiddenMain, !store.sessions.isEmpty {
            // Don't auto-show on every activation (e.g. switching apps). Only when
            // nothing else is visible — same as Dock click with no visible windows.
            if !terminalWindows().contains(where: \.isVisible) {
                showMainWindow()
            }
        }
    }

    func ensureRunning() {
        DispatchQueue.main.async { [weak self] in
            self?.adoptExistingWindows()
        }
    }

    /// Show the one terminal window (works after hide / from launcher IPC / Dock).
    func showMainWindow() {
        adoptExistingWindows()
        collapseDuplicateWindows()

        NSApp.activate(ignoringOtherApps: true)

        if let window = retainedMainWindow ?? terminalWindows().first {
            retainedMainWindow = window
            window.deminiaturize(nil)
            window.collectionBehavior.insert(.moveToActiveSpace)
            // `orderFrontRegardless` works even when another app (Fastq launcher) is key.
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            return
        }

        // No window instance — recreate the SwiftUI Window scene.
        NotificationCenter.default.post(name: .fastqOpenMainTerminalWindow, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.adoptExistingWindows()
            if let window = self.retainedMainWindow ?? self.terminalWindows().first {
                self.retainedMainWindow = window
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hideMainWindow() {
        adoptExistingWindows()
        if let window = retainedMainWindow {
            window.orderOut(nil)
        }
        for window in terminalWindows() where window !== retainedMainWindow {
            window.orderOut(nil)
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowDestructiveClose {
            if sender === retainedMainWindow {
                retainedMainWindow = nil
            }
            return true
        }
        // Hide instead of destroy — keep the strong reference so launcher can restore it.
        if retainedMainWindow == nil {
            retainedMainWindow = sender
        }
        sender.orderOut(nil)
        return false
    }

    // MARK: - Window identity

    private func adoptExistingWindows() {
        for window in terminalWindows() {
            adopt(window)
        }
    }

    private func adopt(_ window: NSWindow) {
        guard isTerminalWindow(window) else { return }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        if retainedMainWindow == nil {
            retainedMainWindow = window
        }
    }

    private func collapseDuplicateWindows() {
        let windows = terminalWindows()
        guard windows.count > 1 else {
            if retainedMainWindow == nil {
                retainedMainWindow = windows.first
            }
            return
        }

        // Always prefer the retained (original) window — never the newest visible duplicate.
        let keeper: NSWindow
        if let retained = retainedMainWindow, windows.contains(where: { $0 === retained }) {
            keeper = retained
        } else {
            keeper = windows.sorted { $0.windowNumber < $1.windowNumber }.first!
        }
        retainedMainWindow = keeper

        let extras = windows.filter { $0 !== keeper }
        guard !extras.isEmpty else { return }

        allowDestructiveClose = true
        for window in extras {
            window.delegate = nil
            window.close()
        }
        allowDestructiveClose = false
        keeper.delegate = self
    }

    private func terminalWindows() -> [NSWindow] {
        NSApp.windows.filter(isTerminalWindow)
    }

    private func isTerminalWindow(_ window: NSWindow) -> Bool {
        guard window.styleMask.contains(.titled) else { return false }
        guard window.frame.width >= 500, window.frame.height >= 300 else { return false }
        let title = window.title
        return title.isEmpty || title == "Fastq Terminal" || title.hasPrefix("Fastq Terminal")
    }
}

extension Notification.Name {
    static let fastqOpenMainTerminalWindow = Notification.Name("fastq.openMainTerminalWindow")
    static let fastqToggleTerminalSidebar = Notification.Name("fastq.toggleTerminalSidebar")
}

private struct TerminalWindowOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onReceive(NotificationCenter.default.publisher(for: .fastqOpenMainTerminalWindow)) { _ in
                openWindow(id: TerminalAppDelegate.mainWindowID)
            }
    }
}

private struct WindowCloseInterceptor: NSViewRepresentable {
    let appDelegate: TerminalAppDelegate

    func makeNSView(context: Context) -> InterceptorView {
        let view = InterceptorView()
        view.appDelegate = appDelegate
        return view
    }

    func updateNSView(_ nsView: InterceptorView, context: Context) {
        nsView.appDelegate = appDelegate
        DispatchQueue.main.async {
            if let window = nsView.window {
                appDelegate.adoptPublic(window)
            }
        }
    }

    final class InterceptorView: NSView {
        weak var appDelegate: TerminalAppDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                appDelegate?.adoptPublic(window)
            }
        }
    }
}

extension TerminalAppDelegate {
    fileprivate func adoptPublic(_ window: NSWindow) {
        adopt(window)
    }
}
