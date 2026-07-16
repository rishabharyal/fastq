import SwiftUI
import AppKit

@main
struct FastqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No SwiftUI `Settings` scene — accessory apps can't reliably reopen it.
        MenuBarExtra("Fastq", systemImage: "bolt.horizontal.circle.fill") {
            Button("Open Launcher") {
                appDelegate.panelController.show()
            }

            Button("Boards") {
                appDelegate.openBoards()
            }
            .keyboardShortcut("b", modifiers: .command)

            if appDelegate.settings.needsSetup {
                Button("Continue Setup…") {
                    appDelegate.showOnboarding(force: true)
                }
            }

            Divider()

            Button("Settings…") {
                appDelegate.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Fastq") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let sessions = SessionStore()
    let auth = FastplayAuthStore.shared
    lazy var panelController = LauncherPanelController(settings: settings, sessions: sessions)
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var boardController: BoardWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController.onOpenOnboarding = { [weak self] in
            self?.panelController.hide()
            self?.showOnboarding(force: true)
        }
        panelController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        panelController.onOpenAccountSettings = { [weak self] in
            self?.openSettings(tab: .account)
        }
        panelController.onOpenBoards = { [weak self] in
            self?.openBoards()
        }
        panelController.setup()

        NotificationCenter.default.addObserver(
            forName: StartAgentForTask.notification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.boardController?.close()
                self?.panelController.show()
            }
        }

        Task { await auth.restoreSession() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func openSettings(tab: SettingsView.SettingsTab = .projects) {
        panelController.hide()
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings, auth: auth) { [weak self] in
                self?.showOnboarding(force: true)
            }
        }
        settingsController?.show(tab: tab)
    }

    func openBoards() {
        panelController.hide()
        if !auth.isLoggedIn {
            openSettings(tab: .account)
            return
        }
        if boardController == nil {
            boardController = BoardWindowController(auth: auth)
        }
        boardController?.show()
    }

    func showOnboarding(force: Bool = false) {
        if !force, settings.hasCompletedOnboarding { return }

        if onboardingController == nil {
            onboardingController = OnboardingWindowController(settings: settings) { [weak self] in
                self?.panelController.show()
            }
        }
        onboardingController?.show()
    }

    private func presentOnboardingIfNeeded() {
        if settings.needsSetup {
            showOnboarding(force: true)
        }
    }
}
