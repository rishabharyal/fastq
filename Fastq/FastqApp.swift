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
    lazy var panelController = LauncherPanelController(settings: settings, sessions: sessions)
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController.onOpenOnboarding = { [weak self] in
            self?.panelController.hide()
            self?.showOnboarding(force: true)
        }
        panelController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        panelController.setup()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func openSettings() {
        panelController.hide()
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings) { [weak self] in
                self?.showOnboarding(force: true)
            }
        }
        settingsController?.show()
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
        // Only the welcome flow — never auto-open Settings.
        if settings.needsSetup {
            showOnboarding(force: true)
        }
    }
}
