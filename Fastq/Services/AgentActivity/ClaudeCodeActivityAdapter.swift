import Foundation

/// Claude Code: install Fastq hook settings that emit `fastq:<activity>` OSC titles.
struct ClaudeCodeActivityAdapter: AgentActivityAdapter {
    var toolID: String { AgentToolKind.claudeCode.rawValue }

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Fastq", isDirectory: true)
            .appendingPathComponent("claude", isDirectory: true)
    }

    private var settingsURL: URL {
        supportDir.appendingPathComponent("settings.json")
    }

    private var hookScriptURL: URL {
        supportDir.appendingPathComponent("status-hook.sh")
    }

    func prepareLaunch() throws -> AgentLaunchAugmentation {
        let settings = try installHookFiles()
        return AgentLaunchAugmentation(
            extraArguments: ["--settings", settings.path],
            prepare: nil
        )
    }

    @discardableResult
    private func installHookFiles() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        let script = hookScriptURL
        try Self.hookScriptSource.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let settings = settingsURL
        let payload = Self.settingsPayload(hookCommand: script.path)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settings, options: .atomic)
        return settings
    }

    private static func settingsPayload(hookCommand: String) -> [String: Any] {
        let handler: [String: Any] = [
            "type": "command",
            "command": hookCommand
        ]
        let group: [String: Any] = [
            "matcher": "",
            "hooks": [handler]
        ]
        let events = [
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "Notification",
            "PermissionRequest",
            "Stop",
            "StopFailure",
            "SubagentStop"
        ]
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [group]
        }
        return ["hooks": hooks]
    }

    private static var hookScriptSource: String {
        #"""
        #!/bin/bash
        # Fastq activity hook (Claude Code) — emits canonical OSC titles.
        set -euo pipefail
        input=$(cat || true)
        event=$(/usr/bin/python3 -c '
        import json, sys
        raw = sys.stdin.read()
        try:
            data = json.loads(raw) if raw.strip() else {}
        except Exception:
            data = {}
        print(data.get("hook_event_name") or data.get("hookEventName") or "")
        ' <<<"$input")

        case "$event" in
          Notification|PermissionRequest|Elicitation)
            status="waiting"
            ;;
          Stop|StopFailure|SubagentStop)
            status="done"
            ;;
          *)
            status="working"
            ;;
        esac

        /usr/bin/python3 -c '
        import json, sys
        status = sys.argv[1]
        seq = "\033]0;fastq:%s\007" % status
        print(json.dumps({"terminalSequence": seq}))
        ' "$status"
        """#
    }
}
