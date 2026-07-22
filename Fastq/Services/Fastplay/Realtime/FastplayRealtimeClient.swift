import Foundation
import Network
import os

/// Lifecycle logging for the websocket.
///
/// The socket runs unattended in the background and is expected to heal itself,
/// so every state transition is recorded: without this, a connection that never
/// establishes is indistinguishable from one that is simply idle.
private let realtimeLog = Logger(subsystem: "app.fastq.launcher", category: "realtime")

enum RealtimeClientError: LocalizedError {
    case broadcastingUnavailable

    var errorDescription: String? {
        switch self {
        case .broadcastingUnavailable:
            return "Realtime notifications are not enabled on the server."
        }
    }
}

/// Owns the websocket connection to Fastplay and turns inbound frames into
/// user-visible notifications.
///
/// An actor, so all connection state is mutated off the main thread and the UI
/// is only touched at the presentation boundary. Collaborators are injected
/// behind narrow protocols: the client orchestrates the lifecycle and knows
/// nothing about `URLSession`, `UNUserNotificationCenter`, or the HTTP API.
actor FastplayRealtimeClient {

    // MARK: - Dependencies

    private let transport: RealtimeTransport
    private let config: RealtimeConfigProviding
    private let authorizer: RealtimeChannelAuthorizing
    private let backfill: RealtimeBackfilling
    private let presenter: RealtimeNotificationPresenting

    // MARK: - State

    private var connectionTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var policy = ReconnectPolicy()
    private var pathMonitor: NWPathMonitor?
    /// Last known connectivity, so only offline→online transitions force a
    /// reconnect. Starts satisfied: the common case is launching while online,
    /// and the first path callback must not be mistaken for a recovery.
    private var isNetworkSatisfied = true

    private var socketID: String?
    private var lastFrameAt = Date()
    private var isSubscribed = false
    /// Config for the connection currently being served, so the subscribe step
    /// does not refetch it.
    private var activeConfig: FastplayRealtimeConfig?

    /// Ids already presented, so a notification seen live is not shown again
    /// when it reappears in the reconnect backfill.
    private var seenIDs: Set<String> = []
    private var seenOrder: [String] = []
    /// Whether the first backfill of this session has run. Distinguishes
    /// "notifications waiting since last time" from "arrived while the socket
    /// was briefly down" — only the latter is worth interrupting the user for.
    private var hasSyncedOnce = false

    /// Reverb pings every 60s when idle; missing two of those means the socket
    /// is gone even if the OS has not surfaced an error yet.
    private static let activityTimeout: TimeInterval = 150
    private static let seenLimit = 500
    /// Most banners shown at once after a reconnect; the remainder stay unread
    /// in the notification list rather than burying the screen.
    private static let backfillPresentLimit = 3

    init(
        transport: RealtimeTransport = URLSessionRealtimeTransport(),
        config: RealtimeConfigProviding,
        authorizer: RealtimeChannelAuthorizing,
        backfill: RealtimeBackfilling,
        presenter: RealtimeNotificationPresenting
    ) {
        self.transport = transport
        self.config = config
        self.authorizer = authorizer
        self.backfill = backfill
        self.presenter = presenter
    }

    // MARK: - Lifecycle

    /// Starts connecting and keeps the connection up until `stop()`.
    /// Idempotent: calling it while already running is a no-op.
    func start() {
        guard connectionTask == nil else { return }
        realtimeLog.info("starting realtime client")

        requestNotificationPermission()
        startPathMonitor()

        connectionTask = Task { [weak self] in
            await self?.runConnectionLoop()
        }
    }

    /// Tears the connection down. Used on sign-out and app termination.
    func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        isSubscribed = false
        socketID = nil
        transport.disconnect()
        FastplayRealtimeEvent.postConnectionChanged(isConnected: false)
    }

    /// Drops the current socket so the loop reconnects immediately.
    ///
    /// Called when the machine wakes or the network path changes: TCP can stay
    /// open-but-dead across a sleep, and waiting for the watchdog would leave a
    /// window where notifications are silently missed.
    func reconnectNow() {
        guard connectionTask != nil else { return }
        policy.reset()
        transport.disconnect()
    }

    /// Asks for notification permission without blocking the connection.
    private func requestNotificationPermission() {
        Task { [presenter] in
            await presenter.prepare()
        }
    }

    // MARK: - Connection loop

    private func runConnectionLoop() async {
        while !Task.isCancelled {
            do {
                try await connectOnce()
                realtimeLog.info("socket closed; will reconnect")
            } catch {
                // Any failure is a reason to retry, but never silently: a
                // config fetch that always fails would otherwise look identical
                // to a healthy idle connection.
                realtimeLog.error("connection attempt failed: \(error.localizedDescription, privacy: .public)")
            }

            isSubscribed = false
            socketID = nil
            FastplayRealtimeEvent.postConnectionChanged(isConnected: false)

            if Task.isCancelled { break }

            let delay = policy.nextDelay()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// One full connection attempt. Returns when the socket closes for any reason.
    private func connectOnce() async throws {
        let connection = try await config.realtimeConfig()

        guard connection.enabled, connection.isUsable, let url = connection.socketURL else {
            // Broadcasting is off server-side. Backing off rather than failing
            // hard means enabling it later needs no client restart.
            throw RealtimeClientError.broadcastingUnavailable
        }

        realtimeLog.info("connecting to \(url.host ?? "?", privacy: .public)")
        activeConfig = connection
        lastFrameAt = Date()
        startWatchdog()
        defer {
            watchdogTask?.cancel()
            watchdogTask = nil
            activeConfig = nil
        }

        // The stream finishes when the socket closes, which returns control to
        // the reconnect loop.
        for await text in transport.connect(to: url) {
            if Task.isCancelled { break }
            await handle(text)
        }
    }

    // MARK: - Frame handling

    private func handle(_ text: String) async {
        lastFrameAt = Date()

        guard let frame = PusherProtocol.decode(text) else { return }

        switch PusherProtocol.classify(frame) {
        case .connectionEstablished(let id):
            socketID = id
            realtimeLog.info("handshake complete")
            await subscribeToUserChannel()

        case .subscriptionSucceeded:
            realtimeLog.info("subscribed to user channel")
            isSubscribed = true
            policy.reset()
            FastplayRealtimeEvent.postConnectionChanged(isConnected: true)
            // Anything that arrived while disconnected is not replayed by the
            // server, so pull it from the API once the channel is live.
            await backfillMissed()

        case .ping:
            if let pong = PusherProtocol.pong() {
                try? await transport.send(pong)
            }

        case .pong, .ignored:
            break

        case .error(let message, let code):
            // 4009/4100-range codes are fatal per the Pusher spec; treating all
            // errors as "drop and retry" keeps the policy simple and safe.
            realtimeLog.error("socket error \(code ?? -1): \(message, privacy: .public)")
            transport.disconnect()

        case .notification(let payload):
            await deliver(payload)
        }
    }

    private func subscribeToUserChannel() async {
        // Reuse the config already fetched for this connection rather than
        // paying for another round trip on every handshake.
        guard let socketID, let channel = activeConfig?.userChannel else { return }

        do {
            let auth = try await authorizer.authorize(channel: channel, socketID: socketID)
            guard let frame = PusherProtocol.subscribe(channel: channel, auth: auth) else { return }
            try await transport.send(frame)
        } catch {
            realtimeLog.error("channel authorization failed: \(error.localizedDescription, privacy: .public)")
            // Drop the socket; the loop will back off and try again, by which
            // point a token refresh may have succeeded.
            transport.disconnect()
        }
    }

    private func deliver(_ payload: Data) async {
        guard let notification = try? JSONDecoder().decode(FastplayRealtimeNotification.self, from: payload) else {
            return
        }
        await present(notification)
    }

    private func backfillMissed() async {
        guard let missed = try? await backfill.recentNotifications(limit: 20) else { return }

        // On the first connection of a session, treat everything already unread
        // as history: the user did not just miss it, it was waiting for them.
        // Replaying it as banners on every launch would be noise. Recording the
        // ids still matters, so a later reconnect does not present them either.
        guard hasSyncedOnce else {
            for notification in missed {
                remember(notification.id)
            }
            hasSyncedOnce = true
            realtimeLog.info("initial sync: \(missed.count, privacy: .public) unread marked as seen")
            return
        }

        // Oldest first, so the newest ends up on top.
        let toPresent = missed.reversed().filter { !seenIDs.contains($0.id) }
        if toPresent.isEmpty { return }

        realtimeLog.info("backfilling \(toPresent.count, privacy: .public) missed notification(s)")

        // Cap the burst: after a long outage, showing every missed item at once
        // buries the screen. The rest stay unread in the notification list.
        for notification in toPresent.prefix(Self.backfillPresentLimit) {
            await present(notification)
        }
        for notification in toPresent.dropFirst(Self.backfillPresentLimit) {
            remember(notification.id)
        }
    }

    /// Presents a notification unless it has already been seen.
    private func present(_ notification: FastplayRealtimeNotification) async {
        guard !seenIDs.contains(notification.id) else {
            realtimeLog.debug("skipping duplicate notification \(notification.id, privacy: .public)")
            return
        }
        remember(notification.id)
        realtimeLog.info("presenting \(notification.kind.rawValue, privacy: .public): \(notification.body, privacy: .public)")

        await presenter.present(notification)
        FastplayRealtimeEvent.post(notification)
    }

    private func remember(_ id: String) {
        seenIDs.insert(id)
        seenOrder.append(id)
        // Bound the set: this process can stay alive for weeks.
        if seenOrder.count > Self.seenLimit {
            let overflow = seenOrder.count - Self.seenLimit
            for stale in seenOrder.prefix(overflow) {
                seenIDs.remove(stale)
            }
            seenOrder.removeFirst(overflow)
        }
    }

    // MARK: - Liveness

    /// Watches for a socket that stopped delivering without reporting an error.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self else { return }
                await self.dropIfStale()
            }
        }
    }

    private func dropIfStale() {
        guard isSubscribed else { return }
        if Date().timeIntervalSince(lastFrameAt) > Self.activityTimeout {
            realtimeLog.notice("no traffic for \(Int(Self.activityTimeout))s - reconnecting")
            transport.disconnect()
        }
    }

    /// Reacts only to a genuine offline→online transition.
    ///
    /// `NWPathMonitor` reports every path change, not just connectivity loss —
    /// a DNS or gateway update on the active interface fires it too. Treating
    /// each of those as "the network came back" and dropping the socket would
    /// tear down a perfectly healthy connection every time the path was touched.
    private func handlePathChange(isSatisfied: Bool) {
        defer { isNetworkSatisfied = isSatisfied }

        guard isSatisfied, isNetworkSatisfied == false else { return }
        realtimeLog.info("network restored - reconnecting")
        reconnectNow()
    }

    /// Reconnects as soon as the network comes back, rather than waiting out
    /// the current backoff delay.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { await self?.handlePathChange(isSatisfied: isSatisfied) }
        }
        // A dedicated queue: never the main one.
        monitor.start(queue: DispatchQueue(label: "fastq.realtime.path", qos: .utility))
        pathMonitor = monitor
    }
}
