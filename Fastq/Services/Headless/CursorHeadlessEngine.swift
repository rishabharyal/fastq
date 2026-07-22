import Foundation

/// Builds `cursor-agent -p` invocations and maps its stream-json events.
/// Event shapes verified against a live cursor-agent run (2026-07):
///   {"type":"system","subtype":"init","session_id","model","permissionMode"}
///   {"type":"thinking","subtype":"delta","text"} / {"subtype":"completed"}
///   {"type":"tool_call","subtype":"started"|"completed","call_id",
///    "tool_call":{"<kind>ToolCall":{"args":{…},"result":{"success"|"error":…}},
///                 "toolCallId":…,"startedAtMs":…,"hookAdditionalContexts":[…]}}
///   {"type":"assistant","message":{"content":[{"type":"text","text":…}]}}
///   {"type":"result","subtype":"success","is_error",duration_ms,"result"}
/// Cursor has no permission-prompt hook, so presets map to its flags only.
enum CursorHeadlessEngine {
    static func arguments(
        prompt: String,
        model: AgentModelOption,
        resumeSessionID: String?,
        preset: AgentPermissionPreset
    ) -> [String] {
        var args: [String] = [
            "-p", prompt,
            "--output-format", "stream-json",
            // Fastq project folders are explicitly linked by the user, so the
            // workspace-trust gate would otherwise dead-end the headless run
            // (it prints a plain-text prompt and exits).
            "--trust",
        ]
        if model != .auto {
            args += ["--model", model.cliModelFlag(for: .cursorCLI)]
        }
        if let resumeSessionID {
            args += ["--resume", resumeSessionID]
        }
        if preset == .fullAuto {
            args += ["--force"]
        }
        return args
    }

    static func parse(line: String) -> [AgentEngineEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        switch type {
        case "system":
            guard json["subtype"] as? String == "init" else { return [] }
            return [.sessionStarted(
                engineSessionID: json["session_id"] as? String ?? "",
                model: json["model"] as? String
            )]

        case "thinking":
            // Reasoning deltas — surfaced as live status, not transcript.
            return [.thinking]

        case "assistant":
            // Cursor emits complete message segments (no deltas without
            // --stream-partial-output); treat each as a text block.
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return []
            }
            let text = content
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined()
            return text.isEmpty ? [] : [.assistantText(text, key: nil)]

        case "tool_call":
            let callID = json["call_id"] as? String ?? UUID().uuidString
            let subtype = json["subtype"] as? String
            let toolCall = json["tool_call"] as? [String: Any] ?? [:]
            // The tool payload key sits alongside metadata keys
            // (toolCallId, startedAtMs, hookAdditionalContexts…) — pick the
            // one that is actually a tool.
            guard let kindKey = toolCall.keys.first(where: {
                $0.hasSuffix("ToolCall") || $0 == "function"
            }) else {
                return []
            }
            let payload = toolCall[kindKey] as? [String: Any] ?? [:]
            let args = payload["args"] as? [String: Any] ?? [:]

            switch subtype {
            case "started":
                return [.toolStarted(
                    id: callID,
                    name: prettyToolName(kindKey, args: args),
                    summary: summarize(args),
                    isSubagent: false
                )]
            case "completed":
                let result = payload["result"] as? [String: Any]
                let failed = result?["error"] != nil
                return [.toolFinished(id: callID, ok: !failed)]
            default:
                return []
            }

        case "result":
            let isError = json["is_error"] as? Bool ?? false
            return [.finished(
                ok: !isError,
                resultText: json["result"] as? String ?? "",
                costUSD: nil,
                durationMs: json["duration_ms"] as? Int
            )]

        default:
            return []
        }
    }

    /// "readToolCall" → "read", "shellToolCall" → "shell"; MCP/function
    /// tools use their function name when present.
    private static func prettyToolName(_ key: String, args: [String: Any]) -> String {
        if key == "function" {
            if let name = args["name"] as? String { return name.lowercased() }
            return "tool"
        }
        if key.hasSuffix("ToolCall") {
            let base = String(key.dropLast("ToolCall".count))
            // camelCase → spaced lowercase ("codebaseSearch" → "codebase search")
            var words: [String] = []
            var current = ""
            for char in base {
                if char.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = String(char).lowercased()
                } else {
                    current.append(char)
                }
            }
            if !current.isEmpty { words.append(current) }
            return words.joined(separator: " ").lowercased()
        }
        return key.lowercased()
    }

    private static func summarize(_ args: [String: Any]) -> String {
        if let path = args["path"] as? String, !path.isEmpty {
            return (path as NSString).abbreviatingWithTildeInPath
        }
        if let command = args["command"] as? String, !command.isEmpty {
            return String(command.prefix(80))
        }
        if let pattern = args["globPattern"] as? String, !pattern.isEmpty {
            return pattern
        }
        if let pattern = args["pattern"] as? String, !pattern.isEmpty {
            return pattern
        }
        if let query = args["query"] as? String, !query.isEmpty {
            return query
        }
        let interesting = args.filter { !["toolCallId", "timeout", "workingDirectory"].contains($0.key) }
        if !interesting.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: interesting),
           let text = String(data: data, encoding: .utf8), text != "{}" {
            return String(text.prefix(80))
        }
        return ""
    }
}
