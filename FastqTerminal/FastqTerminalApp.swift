import SwiftUI
import AppKit

@main
struct FastqTerminalApp: App {
    @NSApplicationDelegateAdaptor(TerminalAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Fastq Terminal") {
            TerminalRootView(store: appDelegate.store)
                .onAppear {
                    appDelegate.ensureRunning()
                }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    let store = TerminalSessionStore()
    private var ipc: TerminalIPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let server = TerminalIPCServer(store: store)
        server.start()
        ipc = server
        NSApp.activate(ignoringOtherApps: true)
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

    func ensureRunning() {
        // no-op; keeps window alive when activated from launcher
    }
}
