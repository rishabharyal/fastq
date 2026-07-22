import Foundation

/// Encoding and decoding for the Pusher wire protocol that Reverb speaks.
///
/// Pure value types with no I/O or state, so the protocol handling is testable
/// in isolation from the socket and from the client's connection lifecycle.
enum PusherProtocol {

    /// A frame received from the server.
    struct IncomingFrame {
        let event: String
        let channel: String?
        /// Raw `data` payload. The server double-encodes this as a JSON *string*
        /// for most events, but sends a bare object for some; both are
        /// normalised to UTF-8 JSON bytes here.
        let payload: Data?
    }

    /// Server events the client acts on. Anything else is ignored rather than
    /// treated as an error, so new server-side frames can't break the client.
    enum ServerEvent {
        case connectionEstablished(socketID: String)
        case subscriptionSucceeded
        case ping
        case pong
        case error(message: String, code: Int?)
        /// An application event carrying a notification payload.
        case notification(Data)
        case ignored
    }

    // MARK: - Decoding

    static func decode(_ text: String) -> IncomingFrame? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = root["event"] as? String else {
            return nil
        }

        let payload: Data?
        switch root["data"] {
        case let string as String:
            payload = string.data(using: .utf8)
        case let object as [String: Any]:
            payload = try? JSONSerialization.data(withJSONObject: object)
        default:
            payload = nil
        }

        return IncomingFrame(event: event, channel: root["channel"] as? String, payload: payload)
    }

    static func classify(_ frame: IncomingFrame) -> ServerEvent {
        switch frame.event {
        case "pusher:connection_established":
            guard let payload = frame.payload,
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let socketID = object["socket_id"] as? String else {
                return .error(message: "Malformed connection_established frame.", code: nil)
            }
            return .connectionEstablished(socketID: socketID)

        case "pusher_internal:subscription_succeeded":
            return .subscriptionSucceeded

        case "pusher:ping":
            return .ping

        case "pusher:pong":
            return .pong

        case "pusher:error":
            let object = frame.payload
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return .error(
                message: object?["message"] as? String ?? "Unknown websocket error.",
                code: object?["code"] as? Int
            )

        default:
            // Every notification arrives under the same event name; the payload's
            // `type` field distinguishes them. Frames beginning with `pusher` are
            // protocol chatter the client does not need.
            guard !frame.event.hasPrefix("pusher"), let payload = frame.payload else {
                return .ignored
            }
            return .notification(payload)
        }
    }

    // MARK: - Encoding

    static func subscribe(channel: String, auth: String) -> String? {
        encode(event: "pusher:subscribe", data: ["channel": channel, "auth": auth])
    }

    static func unsubscribe(channel: String) -> String? {
        encode(event: "pusher:unsubscribe", data: ["channel": channel])
    }

    static func pong() -> String? {
        encode(event: "pusher:pong", data: [:])
    }

    private static func encode(event: String, data: [String: String]) -> String? {
        let frame: [String: Any] = ["event": event, "data": data]
        guard let encoded = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
}
