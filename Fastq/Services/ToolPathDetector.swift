import Foundation

enum ToolPathDetector {
    static func detect(kind: AgentToolKind) -> DetectedToolPath {
        DetectedToolPath(kind: kind, path: resolve(kind))
    }

    static func detectAll() -> [DetectedToolPath] {
        AgentToolKind.agentCases.map(detect)
    }

    static func resolve(_ kind: AgentToolKind) -> String? {
        // Prefer known install paths for this tool (avoids `agent` name clashes).
        for path in kind.searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let command = kind.defaultCommand
        if command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) {
            return command
        }

        return resolveOnPath(command)
    }

    /// Prefer Homebrew / local installs, then `which`.
    static func resolve(_ command: String) -> String? {
        if command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) {
            return command
        }
        return resolveOnPath(command)
    }

    private static func resolveOnPath(_ command: String) -> String? {
        let base = (command as NSString).lastPathComponent
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/\(base)",
            "/usr/local/bin/\(base)",
            "\(home)/.local/bin/\(base)",
            "\(home)/.grok/bin/\(base)",
            "\(home)/.opencode/bin/\(base)",
            "\(home)/.cursor/bin/\(base)",
            "/usr/bin/\(base)"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zsh", "-lc", "which \(shellEscape(base))"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let output, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
                return output
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
