import Foundation

/// Resolves where to connect.
protocol RealtimeConfigProviding: Sendable {
    func realtimeConfig() async throws -> FastplayRealtimeConfig
}

/// Authorizes a private channel for a socket.
protocol RealtimeChannelAuthorizing: Sendable {
    /// Returns the Pusher auth signature for the channel.
    ///
    /// Implementations must refresh an expired access token and retry once:
    /// the socket is authorized only at subscribe time, so a stale token on
    /// reconnect would otherwise leave the client permanently silent.
    func authorize(channel: String, socketID: String) async throws -> String
}

/// Fetches notifications missed while disconnected.
protocol RealtimeBackfilling: Sendable {
    func recentNotifications(limit: Int) async throws -> [FastplayRealtimeNotification]
}

/// Reports whether a user session exists to connect with.
@MainActor
protocol RealtimeSessionObserving: AnyObject {
    var isLoggedIn: Bool { get }
}

extension FastplayAuthStore: RealtimeSessionObserving {}

/// Adapts the shared API client to the narrow capabilities the realtime client
/// needs.
///
/// Splitting these into three protocols rather than one wide one keeps the
/// realtime client depending only on what it uses, and lets each be stubbed
/// independently in tests.
struct FastplayRealtimeServices: RealtimeConfigProviding, RealtimeChannelAuthorizing, RealtimeBackfilling {

    private let client: FastplayAPIClient

    init(client: FastplayAPIClient = .shared) {
        self.client = client
    }

    func realtimeConfig() async throws -> FastplayRealtimeConfig {
        try await client.broadcastingConnection()
    }

    func authorize(channel: String, socketID: String) async throws -> String {
        try await client.authorizeBroadcastChannel(channel: channel, socketID: socketID)
    }

    func recentNotifications(limit: Int) async throws -> [FastplayRealtimeNotification] {
        try await client.recentNotifications(limit: limit)
    }
}
