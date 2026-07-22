import Foundation
import UserNotifications
import os

private let presenterLog = Logger(subsystem: "app.fastq.launcher", category: "realtime")

/// Presents a realtime notification to the user.
///
/// An abstraction so the realtime client never depends on a presentation
/// technology: the socket layer decides *that* something should be shown, this
/// decides *how*.
protocol RealtimeNotificationPresenting: Sendable {
    /// Requests any permission the presenter needs. Safe to call repeatedly.
    func prepare() async

    /// Shows the notification.
    ///
    /// Returns `false` when this presenter could not display it — for example
    /// when the user has denied notification permission — so a caller can fall
    /// back to another presenter rather than dropping the notification.
    @discardableResult
    func present(_ notification: FastplayRealtimeNotification) async -> Bool
}

/// Tries each presenter in order until one succeeds.
///
/// Lets the app prefer native macOS notifications and degrade to an in-app
/// banner without either presenter knowing about the other.
struct ChainedNotificationPresenter: RealtimeNotificationPresenting {
    let presenters: [RealtimeNotificationPresenting]

    func prepare() async {
        for presenter in presenters {
            await presenter.prepare()
        }
    }

    @discardableResult
    func present(_ notification: FastplayRealtimeNotification) async -> Bool {
        for presenter in presenters {
            if await presenter.present(notification) {
                return true
            }
        }
        return false
    }
}

/// Delivers native macOS notifications via `UNUserNotificationCenter`.
///
/// These are the system banners in the top-right corner, so they appear whether
/// or not the launcher panel is open — which matters for a menu-bar accessory
/// app (`LSUIElement`) that usually has no visible window.
final class SystemNotificationPresenter: NSObject, RealtimeNotificationPresenting, @unchecked Sendable {

    /// Set when the user taps a notification, so the app can navigate to the task.
    private let onSelect: @Sendable (FastplayRealtimeNotification) -> Void

    private let center = UNUserNotificationCenter.current()
    /// Retains payloads so a tap can be resolved back to its notification.
    private let lock = NSLock()
    private var pending: [String: FastplayRealtimeNotification] = [:]

    init(onSelect: @escaping @Sendable (FastplayRealtimeNotification) -> Void) {
        self.onSelect = onSelect
        super.init()
        center.delegate = self
    }

    /// Retains a payload under the lock.
    ///
    /// Kept synchronous on purpose: `NSLock` must not be held across an `await`,
    /// and taking it inside an async function is an error in Swift 6.
    private func remember(_ notification: FastplayRealtimeNotification) {
        lock.lock()
        defer { lock.unlock() }
        pending[notification.id] = notification
        // Bound the map so a long-running session cannot grow it without limit;
        // the payload is only needed until the user taps the banner.
        if pending.count > 200 {
            pending.removeAll()
            pending[notification.id] = notification
        }
    }

    func prepare() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            presenterLog.info("notification authorization granted: \(granted, privacy: .public)")
        } catch {
            // Typically an unsigned or non-bundled build, where the
            // notification centre refuses to register the app at all.
            presenterLog.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func present(_ notification: FastplayRealtimeNotification) async -> Bool {
        // Checked per notification rather than cached: a user who grants
        // permission later starts seeing banners without restarting the app.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else {
            // Log rather than fail quietly: a revoked permission is otherwise
            // indistinguishable from notifications never arriving at all.
            presenterLog.notice(
                "system notifications unavailable (status \(settings.authorizationStatus.rawValue, privacy: .public)) - falling back"
            )
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if let taskTitle = notification.taskTitle, !taskTitle.isEmpty {
            content.subtitle = taskTitle
        }

        remember(notification)

        // The notification id doubles as the request id, so the same
        // notification arriving live and again through reconnect backfill
        // replaces its banner instead of stacking a duplicate.
        let request = UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            return true
        } catch {
            presenterLog.error("failed to post system notification: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

extension SystemNotificationPresenter: UNUserNotificationCenterDelegate {

    /// Show the banner even when Fastq is the frontmost app.
    ///
    /// macOS suppresses notifications for the active app by default, which for
    /// a menu-bar app means they vanish exactly when the user is working in it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier

        lock.lock()
        let payload = pending.removeValue(forKey: id)
        lock.unlock()

        if let payload {
            onSelect(payload)
        }
        completionHandler()
    }
}
