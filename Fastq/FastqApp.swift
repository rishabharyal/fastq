import SwiftUI
import AppKit
import Combine
import os

private let realtimeBootLog = Logger(subsystem: "app.fastq.launcher", category: "realtime")

/// Custom entry point: when the Claude CLI spawns this binary as its MCP
/// permission-prompt server (`Fastq --fastq-approve <port> <token>`), run
/// the stdio server instead of booting the app.
@main
enum FastqMain {
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--fastq-approve"),
           args.count > index + 2,
           let port = UInt16(args[index + 1]) {
            FastqApproveServer.run(port: port, token: args[index + 2])
        }
        FastqApp.main()
    }
}

/// Tasks assigned to the signed-in user — feeds the menu-bar section and
/// the Projects-mode "Mine" filter. Refreshes on a slow timer + on demand.
@MainActor
final class AssignedTasksStore: ObservableObject {
    static let shared = AssignedTasksStore()

    @Published private(set) var tasks: [FastplayTask] = []
    private var lastFetch: Date?

    func refreshIfStale() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 120 { return }
        refresh()
    }

    func refresh() {
        guard FastplayAuthStore.shared.isLoggedIn,
              let me = FastplayAuthStore.shared.user?.id else {
            tasks = []
            return
        }
        lastFetch = Date()
        Task {
            let mine = (try? await FastplayAPIClient.shared.listTasks(assigneeID: me, perPage: 50)) ?? []
            self.tasks = mine.filter { !$0.isCompleted }
        }
    }
}

struct FastqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var assigned = AssignedTasksStore.shared

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

            if appDelegate.auth.isLoggedIn {
                Divider()

                Text("Assigned Tasks — \(assigned.tasks.count) open")

                ForEach(assigned.tasks.prefix(6)) { task in
                    Button("• \(task.title)") {
                        appDelegate.openBoards()
                    }
                }
                if assigned.tasks.count > 6 {
                    Button("…and \(assigned.tasks.count - 6) more") {
                        appDelegate.openBoards()
                    }
                }
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
    let auth = FastplayAuthStore.shared
    lazy var panelController = LauncherPanelController(settings: settings, sessions: sessions)
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var boardController: BoardWindowController?
    private var realtime: FastplayRealtimeClient?
    private var realtimeSessionObserver: AnyCancellable?

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
        // Mount the launcher up front: it owns the agent-launch observer, which
        // has to be live before the first StartAgentForTask notification lands.
        panelController.prepare()

        NotificationCenter.default.addObserver(
            forName: StartAgentForTask.notification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Keep the board up when it's the surface the user started from:
                // the run opens as a tab there once the session appears.
                if self?.boardController?.isVisible == true {
                    // LauncherView drives the actual launch, so it must be
                    // mounted even though we're leaving the panel hidden.
                    self?.panelController.prepare()
                } else {
                    self?.panelController.show()
                }
            }
        }

        Task {
            await auth.restoreSession()
            AssignedTasksStore.shared.refresh()
            startRealtimeIfSignedIn()
        }

        realtimeBootLog.info("realtime: app launched, wiring observers")
        observeRealtimeSessionChanges()
        observeWakeForRealtime()

        // Keep the menu's assigned-task list fresh in the background.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                AssignedTasksStore.shared.refreshIfStale()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.presentOnboardingIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the socket deliberately so the server sees a clean disconnect
        // rather than waiting for the connection to time out.
        guard let realtime else { return }
        Task { await realtime.stop() }
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
            boardController = BoardWindowController(auth: auth, sessions: sessions)
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

    // MARK: - Realtime notifications

    /// Opens the websocket once a session exists.
    ///
    /// Connecting is pointless before sign-in: channel authorization needs a
    /// token, so an early socket would only fail and back off.
    private func startRealtimeIfSignedIn() {
        guard auth.isLoggedIn else {
            realtimeBootLog.info("realtime: not starting, signed out")
            return
        }
        guard realtime == nil else {
            realtimeBootLog.info("realtime: already running")
            return
        }
        realtimeBootLog.info("realtime: starting client")

        let services = FastplayRealtimeServices()

        let system = SystemNotificationPresenter { notification in
            // The UNUserNotificationCenter delegate callback is not main-isolated.
            Task { @MainActor [weak self] in
                self?.openTask(from: notification)
            }
        }
        let banner = FloatingBannerPresenter { [weak self] notification in
            self?.openTask(from: notification)
        }

        // Prefer real macOS notifications; fall back to an in-app banner when
        // the system refuses them — notably for ad-hoc signed builds, where
        // UNUserNotificationCenter rejects the app outright.
        let presenter = ChainedNotificationPresenter(presenters: [system, banner])

        let client = FastplayRealtimeClient(
            config: services,
            authorizer: services,
            backfill: services,
            presenter: presenter
        )
        realtime = client
        Task { await client.start() }
    }

    /// Reconnects the socket when the machine wakes.
    ///
    /// A websocket can survive sleep as an open-but-dead TCP connection, so
    /// waiting for the liveness watchdog would leave a window where
    /// notifications are silently missed. Registered once for the app's
    /// lifetime — doing it per sign-in would stack an observer per session.
    private func observeWakeForRealtime() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let client = self?.realtime else { return }
                await client.reconnectNow()
            }
        }
    }

    /// Starts or stops the socket as the user signs in and out.
    private func observeRealtimeSessionChanges() {
        realtimeSessionObserver = auth.$isLoggedIn
            .removeDuplicates()
            .sink { [weak self] isLoggedIn in
                Task { @MainActor in
                    guard let self else { return }
                    if isLoggedIn {
                        self.startRealtimeIfSignedIn()
                    } else {
                        await self.realtime?.stop()
                        self.realtime = nil
                    }
                }
            }
    }

    /// Opens the board when a notification banner is clicked.
    private func openTask(from notification: FastplayRealtimeNotification) {
        AssignedTasksStore.shared.refresh()
        openBoards()
    }
}
