import Foundation

/// Cross-window fan-out for realtime notifications.
///
/// `BoardStore` is not a singleton — the launcher and the Boards window each
/// own an independent instance — so pushing socket events into one store would
/// leave the other stale. Broadcasting through `NotificationCenter` lets every
/// interested store observe on its own terms, and matches how the app already
/// passes messages between windows (see `StartAgentForTask`).
enum FastplayRealtimeEvent {
    /// A realtime notification arrived, live or via reconnect backfill.
    static let received = Notification.Name("fastq.fastplay.realtimeNotificationReceived")

    /// Socket connection state changed; useful for a status indicator.
    static let connectionChanged = Notification.Name("fastq.fastplay.realtimeConnectionChanged")

    private static let payloadKey = "notification"
    private static let connectedKey = "isConnected"

    /// Posts on the main queue: observers drive SwiftUI state.
    static func post(_ notification: FastplayRealtimeNotification) {
        let userInfo: [String: Any] = [payloadKey: notification]
        if Thread.isMainThread {
            NotificationCenter.default.post(name: received, object: nil, userInfo: userInfo)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: received, object: nil, userInfo: userInfo)
            }
        }
    }

    static func postConnectionChanged(isConnected: Bool) {
        let userInfo: [String: Any] = [connectedKey: isConnected]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: connectionChanged, object: nil, userInfo: userInfo)
        }
    }

    static func notification(from note: Notification) -> FastplayRealtimeNotification? {
        note.userInfo?[payloadKey] as? FastplayRealtimeNotification
    }

    static func isConnected(from note: Notification) -> Bool? {
        note.userInfo?[connectedKey] as? Bool
    }
}
