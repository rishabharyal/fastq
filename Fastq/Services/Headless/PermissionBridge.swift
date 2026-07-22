import Foundation
import Network

/// Localhost TCP server inside the main app. The `--fastq-approve` MCP
/// helper (spawned by the Claude CLI) connects here to relay permission
/// prompts / AskUserQuestion calls, and blocks until the user decides.
///
/// Protocol: one JSON line request → one JSON line response, then close.
@MainActor
final class PermissionBridge {
    static let shared = PermissionBridge()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    /// Per-run token → handler that resolves the request via UI.
    private var handlers: [String: (BridgeRequest) async -> BridgeResponse] = [:]

    func register(token: String, handler: @escaping (BridgeRequest) async -> BridgeResponse) {
        handlers[token] = handler
    }

    func unregister(token: String) {
        handlers.removeValue(forKey: token)
    }

    /// Starts the listener once; returns the bound port.
    @discardableResult
    func ensureStarted() -> UInt16 {
        if let listener, listener.state == .ready { return port }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in
                    self?.receive(on: connection, buffer: Data())
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    Task { @MainActor in
                        self?.port = listener.port?.rawValue ?? 0
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            // `port` may not be set until the ready callback; poll synchronously
            // once — NWListener assigns the port at start for .any in practice.
            if let bound = listener.port?.rawValue {
                port = bound
            }
            return port
        } catch {
            return 0
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }

                if let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    await self.handle(lineData: lineData, connection: connection)
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(lineData: Data, connection: NWConnection) async {
        let fallback = BridgeResponse.deny(message: "Fastq could not route this approval request.")
        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: lineData),
              let handler = handlers[request.token] else {
            send(fallback, on: connection)
            return
        }
        let response = await handler(request)
        send(response, on: connection)
    }

    private func send(_ response: BridgeResponse, on connection: NWConnection) {
        var payload = Data(response.jsonString.utf8)
        payload.append(0x0A)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
