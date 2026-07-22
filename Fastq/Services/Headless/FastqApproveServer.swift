import Foundation

/// MCP stdio server run when the app binary is launched as
/// `Fastq --fastq-approve <port> <token>` (by the Claude CLI via
/// --mcp-config). It exposes one tool, `approve`, wired as the CLI's
/// --permission-prompt-tool; each call is relayed to the main app over
/// localhost TCP and the app's decision is returned as the tool result.
///
/// Runs before AppKit starts — plain stdio loop, blocking, never returns.
enum FastqApproveServer {
    static func run(port: UInt16, token: String) -> Never {
        setbuf(stdout, nil)

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else {
                continue
            }
            let id = request["id"]

            switch method {
            case "initialize":
                let params = request["params"] as? [String: Any]
                let version = params?["protocolVersion"] as? String ?? "2024-11-05"
                reply(id: id, result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "fastq-approve", "version": "1.0.0"],
                ])
            case "notifications/initialized", "notifications/cancelled":
                continue // notifications get no response
            case "ping":
                reply(id: id, result: [:])
            case "tools/list":
                reply(id: id, result: [
                    "tools": [[
                        "name": "approve",
                        "description": "Relays Claude Code permission prompts to the Fastq UI.",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "tool_name": ["type": "string"],
                                "input": ["type": "object", "additionalProperties": true],
                                "tool_use_id": ["type": "string"],
                            ],
                            "additionalProperties": true,
                        ],
                    ]],
                ])
            case "tools/call":
                let params = request["params"] as? [String: Any] ?? [:]
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let resultJSON = relayToApp(port: port, token: token, arguments: arguments)
                reply(id: id, result: [
                    "content": [["type": "text", "text": resultJSON]],
                ])
            default:
                if id != nil {
                    replyError(id: id, code: -32601, message: "Method not found: \(method)")
                }
            }
        }
        exit(0)
    }

    /// Blocking TCP round-trip to the app's PermissionBridge.
    private static func relayToApp(port: UInt16, token: String, arguments: [String: Any]) -> String {
        let denyFallback = "{\"behavior\":\"deny\",\"message\":\"Fastq is not reachable to approve this action.\"}"

        var payload = arguments
        payload["token"] = token
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            return denyFallback
        }
        data.append(0x0A)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return denyFallback }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return denyFallback }

        let sent = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base, raw.count)
        }
        guard sent > 0 else { return denyFallback }

        // Block until the app answers (the user deciding can take minutes —
        // Claude Code keeps the run open while the prompt tool is pending).
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
            if chunk[0..<count].contains(0x0A) { break }
        }
        guard let text = String(data: response, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return denyFallback
        }
        return text
    }

    private static func reply(id: Any?, result: [String: Any]) {
        var message: [String: Any] = ["jsonrpc": "2.0", "result": result]
        message["id"] = id ?? NSNull()
        emit(message)
    }

    private static func replyError(id: Any?, code: Int, message text: String) {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": text],
        ]
        message["id"] = id ?? NSNull()
        emit(message)
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }
}
