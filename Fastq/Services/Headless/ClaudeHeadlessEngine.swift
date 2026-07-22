import Foundation

/// Builds `claude -p` invocations and maps its stream-json lines to
/// `AgentEngineEvent`s. One instance per run (turn).
enum ClaudeHeadlessEngine {
    /// Persistent session arguments: one long-lived process per conversation,
    /// user messages written to stdin as stream-json lines. Mid-turn messages
    /// queue server-side (v2.1.205+) and run as their own turn.
    /// NOTE: never pass `--bare` — bare mode skips OAuth/keychain and would
    /// silently require an API key instead of the user's subscription login.
    static func arguments(
        model: AgentModelOption,
        resumeSessionID: String?,
        preset: AgentPermissionPreset,
        bridgePort: UInt16?,
        bridgeToken: String?
    ) -> [String] {
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if model != .auto {
            args += ["--model", model.cliModelFlag(for: .claudeCode)]
        }
        if let resumeSessionID {
            args += ["--resume", resumeSessionID]
        }
        switch preset {
        case .askMe:
            break // default mode; non-auto-approved tools hit the bridge
        case .acceptEdits:
            args += ["--permission-mode", "acceptEdits"]
        case .fullAuto:
            args += [
                "--permission-mode", "acceptEdits",
                "--allowedTools", "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch",
            ]
        }
        // The approval bridge doubles as the AskUserQuestion channel, so it
        // is wired in every preset (auto-approved tools never reach it).
        if let bridgePort, let bridgeToken, let exe = Bundle.main.executablePath {
            let config = """
            {"mcpServers":{"fastq":{"command":"\(exe)","args":["--fastq-approve","\(bridgePort)","\(bridgeToken)"]}}}
            """
            args += [
                "--mcp-config", config,
                "--permission-prompt-tool", "mcp__fastq__approve",
            ]
        }
        return args
    }

    /// One stdin line carrying a user turn (documented wire format).
    static func userMessageLine(_ text: String) -> String? {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
            "parent_tool_use_id": NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Control request that aborts the in-flight turn (Stop button).
    static func interruptLine() -> String {
        "{\"type\":\"control_request\",\"request_id\":\"\(UUID().uuidString)\",\"request\":{\"subtype\":\"interrupt\"}}"
    }

    /// Parses one stream-json line into engine events.
    static func parse(line: String) -> [AgentEngineEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        switch type {
        case "system":
            switch json["subtype"] as? String {
            case "init":
                let sessionID = json["session_id"] as? String ?? ""
                let model = json["model"] as? String
                return [.sessionStarted(engineSessionID: sessionID, model: model)]
            case "api_retry":
                let attempt = json["attempt"] as? Int ?? 0
                let reason = json["error"] as? String ?? "retrying"
                return [.retrying(attempt: attempt, reason: reason)]
            default:
                return []
            }

        case "stream_event":
            // Only surface main-conversation text deltas; subagent chatter
            // stays behind its Task tool row.
            guard json["parent_tool_use_id"] == nil || json["parent_tool_use_id"] is NSNull else { return [] }
            guard let event = json["event"] as? [String: Any],
                  let delta = event["delta"] as? [String: Any] else {
                return []
            }
            if delta["type"] as? String == "thinking_delta" {
                return [.thinking]
            }
            guard delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else {
                return []
            }
            return [.textDelta(text)]

        case "assistant":
            let isSubagent = !(json["parent_tool_use_id"] == nil || json["parent_tool_use_id"] is NSNull)
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return []
            }
            // Snapshots repeat earlier blocks — key text by message + index,
            // tools dedupe by their unique tool_use id downstream.
            let messageID = message["id"] as? String ?? "msg"
            var events: [AgentEngineEvent] = []
            for (index, block) in content.enumerated() {
                switch block["type"] as? String {
                case "text":
                    if !isSubagent, let text = block["text"] as? String, !text.isEmpty {
                        events.append(.assistantText(text, key: "\(messageID)#\(index)"))
                    }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    events.append(.toolStarted(
                        id: id,
                        name: name,
                        summary: toolSummary(name: name, input: input),
                        isSubagent: isSubagent,
                        detail: toolDetail(name: name, input: input)
                    ))
                default:
                    break
                }
            }
            return events

        case "user":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return []
            }
            var events: [AgentEngineEvent] = []
            for block in content where block["type"] as? String == "tool_result" {
                let id = block["tool_use_id"] as? String ?? ""
                let isError = block["is_error"] as? Bool ?? false
                events.append(.toolFinished(
                    id: id,
                    ok: !isError,
                    resultText: resultText(from: block["content"])
                ))
            }
            return events

        case "result":
            let subtype = json["subtype"] as? String ?? "success"
            let ok = subtype == "success"
            let text = json["result"] as? String ?? (ok ? "" : "Run failed (\(subtype))")
            let cost = json["total_cost_usd"] as? Double
            let duration = json["duration_ms"] as? Int
            return [.finished(ok: ok, resultText: text, costUSD: cost, durationMs: duration)]

        default:
            return []
        }
    }

    /// Compact single-line argument summary for a tool row.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        func short(_ path: String) -> String {
            (path as NSString).abbreviatingWithTildeInPath
        }
        switch name {
        case "Bash":
            return (input["command"] as? String)?.prefix(80).description ?? ""
        case "Read", "Write":
            return (input["file_path"] as? String).map(short) ?? ""
        case "Edit":
            return (input["file_path"] as? String).map(short) ?? ""
        case "Glob", "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = (input["path"] as? String).map(short) ?? ""
            return [pattern, path].filter { !$0.isEmpty }.joined(separator: " · ")
        case "WebSearch":
            return input["query"] as? String ?? ""
        case "WebFetch":
            return input["url"] as? String ?? ""
        case "Task":
            return input["description"] as? String ?? "subagent"
        case "TodoWrite":
            return "update plan"
        default:
            if let data = try? JSONSerialization.data(withJSONObject: input),
               let text = String(data: data, encoding: .utf8) {
                return String(text.prefix(80))
            }
            return ""
        }
    }

    /// Full argument capture for the expandable row. Every lookup is
    /// optional — an unexpected shape degrades to `rawInput` rather than
    /// losing the call.
    static func toolDetail(name: String, input: [String: Any]) -> ToolCallDetail {
        var detail = ToolCallDetail(kind: ToolDetailKind.infer(toolName: name))
        detail.filePath = input["file_path"] as? String ?? input["path"] as? String
        detail.oldString = input["old_string"] as? String
        detail.newString = input["new_string"] as? String
        detail.content = input["content"] as? String ?? input["new_source"] as? String
        detail.command = input["command"] as? String
        detail.pattern = input["pattern"] as? String
            ?? input["query"] as? String
            ?? input["url"] as? String
        if detail.pattern != nil || detail.command == nil {
            detail.searchPath = input["path"] as? String
        }
        if let rawEdits = input["edits"] as? [[String: Any]] {
            let patches = rawEdits.compactMap { edit -> ToolEditPatch? in
                let old = edit["old_string"] as? String
                let new = edit["new_string"] as? String
                guard old != nil || new != nil else { return nil }
                return ToolEditPatch(oldString: old ?? "", newString: new ?? "")
            }
            if !patches.isEmpty { detail.edits = patches }
        }
        // Keep the raw args for anything we do not model (MCP tools, Task,
        // TodoWrite) so "other" rows still expand into something useful.
        if detail.isEmpty || detail.kind == .other {
            detail.rawInput = prettyJSON(input)
        }
        return detail.capped()
    }

    /// tool_result `content` is either a plain string or a block array.
    static func resultText(from value: Any?) -> String? {
        var text: String?
        switch value {
        case let string as String:
            text = string
        case let blocks as [[String: Any]]:
            let parts = blocks.compactMap { block -> String? in
                if let inner = block["text"] as? String { return inner }
                if block["type"] as? String == "image" { return "[image]" }
                return nil
            }
            text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        case let blocks as [Any]:
            text = blocks.compactMap { $0 as? String }.joined(separator: "\n")
        case let dict as [String: Any]:
            text = prettyJSON(dict)
        default:
            text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return ToolDetailLimits.cap(text, ToolDetailLimits.result)
    }

    static func prettyJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8),
              text != "{}" else { return nil }
        return text
    }

    /// Display name for a tool row ("read", "bash" — lowercase like the design).
    static func toolDisplayName(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            return name.split(separator: "_").last.map(String.init)?.lowercased() ?? name
        }
        return name.lowercased()
    }
}
