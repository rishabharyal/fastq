import Foundation

enum RealtimeTransportError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "The websocket is not connected."
        }
    }
}

/// A bidirectional text-frame transport.
///
/// The client depends on this rather than on `URLSessionWebSocketTask` directly,
/// so the connection lifecycle can be driven by a stub in tests and the
/// underlying socket implementation can change without touching the client.
protocol RealtimeTransport: Sendable {
    /// Opens the connection and returns a stream of inbound text frames.
    ///
    /// The stream finishes when the socket closes for any reason; the client
    /// treats completion as the single signal to reconnect, so there is no
    /// separate error callback to keep in sync.
    func connect(to url: URL) -> AsyncStream<String>

    func send(_ text: String) async throws

    func disconnect()
}

/// `URLSessionWebSocketTask`-backed transport.
///
/// Deliberately avoids the shared API client's `URLSession`: that one is
/// `.ephemeral` with JSON headers and a 30s request timeout, none of which suit
/// a long-lived socket.
final class URLSessionRealtimeTransport: NSObject, RealtimeTransport, @unchecked Sendable {

    private let session: URLSession
    /// Guards `task` and `continuation`, which are touched from both the caller
    /// and URLSession's delegate queue.
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<String>.Continuation?

    override init() {
        let config = URLSessionConfiguration.default
        // The socket is expected to idle between events; only the initial
        // connection should time out.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        super.init()
    }

    func connect(to url: URL) -> AsyncStream<String> {
        disconnect()

        let task = session.webSocketTask(with: url)
        let stream = AsyncStream<String> { continuation in
            lock.lock()
            self.task = task
            self.continuation = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.disconnect()
            }
        }

        task.resume()
        receiveLoop(on: task)
        return stream
    }

    /// Pumps frames off the socket until it fails or is closed.
    ///
    /// Recurses per message rather than looping, which is how
    /// `URLSessionWebSocketTask` is designed to be read; each callback runs on
    /// the session's delegate queue, never the main thread.
    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.yield(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.yield(text)
                    }
                @unknown default:
                    break
                }
                // Only keep reading while this is still the active task, so a
                // superseded socket cannot feed frames into a newer stream.
                self.lock.lock()
                let isCurrent = self.task === task
                self.lock.unlock()
                if isCurrent {
                    self.receiveLoop(on: task)
                }

            case .failure:
                // Finishing the stream is the client's signal to reconnect.
                self.finish()
            }
        }
    }

    private func yield(_ text: String) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(text)
    }

    private func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    /// Reads the active task under the lock.
    ///
    /// Kept synchronous on purpose: `NSLock` must not be held across an `await`,
    /// and taking it inside an async function is an error in Swift 6.
    private func currentTask() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    func send(_ text: String) async throws {
        guard let task = currentTask() else {
            throw RealtimeTransportError.notConnected
        }
        try await task.send(.string(text))
    }

    func disconnect() {
        lock.lock()
        let task = self.task
        let continuation = self.continuation
        self.task = nil
        self.continuation = nil
        lock.unlock()

        task?.cancel(with: .goingAway, reason: nil)
        continuation?.finish()
    }
}
