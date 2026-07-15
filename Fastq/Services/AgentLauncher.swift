import Foundation
import AppKit

@MainActor
final class AgentLauncher {
    private let settings: AppSettings
    private let sessions: SessionStore
    private let launchDir: URL

    init(settings: AppSettings, sessions: SessionStore) {
        self.settings = settings
        self.sessions = sessions
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fastq-launches", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.launchDir = dir
    }

    func launch(
        prompt: String,
        project: ProjectFolder,
        tool: ToolConfig,
        model: AgentModelOption,
        attachments: [PromptAttachment],
        extraProjectPaths: [String] = []
    ) async throws -> AgentSession {
        let composedPrompt = composePrompt(prompt: prompt, attachments: attachments)
        var session = AgentSession(
            id: UUID(),
            tool: tool.kind,
            projectName: project.name,
            projectPath: project.path,
            promptPreview: prompt,
            model: model,
            startedAt: Date(),
            processIdentifier: nil,
            terminalWindowID: nil,
            status: .launching
        )
        sessions.add(session)

        do {
            let commandLine = terminalCommand(
                kind: tool.kind,
                command: tool.commandPath,
                prompt: composedPrompt,
                model: model,
                projectPath: project.path,
                extraProjectPaths: extraProjectPaths
            )
            // Codex boots a cleaner full TUI when the prompt is typed after start.
            let injectPrompt = tool.kind == .codexCLI
            let info = try await FastqTerminalClient.shared.createSession(
                CreateSessionRequest(
                    sessionID: session.id,
                    title: session.title,
                    projectName: project.name,
                    projectPath: project.path,
                    command: commandLine,
                    prompt: injectPrompt ? composedPrompt : "",
                    tool: tool.kind.rawValue
                )
            )
            session.processIdentifier = info.pid
            session.hostedInFastqTerminal = true
            session.status = .running
            sessions.update(session)
            return session
        } catch {
            sessions.remove(session.id)
            throw error
        }
    }

    func focus(_ session: AgentSession) {
        if session.hostedInFastqTerminal {
            Task {
                // Terminal was Cmd+Q'd — drop the stale row instead of pretending it still runs.
                if !FastqTerminalClient.shared.isTerminalProcessRunning() {
                    sessions.remove(session.id)
                    return
                }
                do {
                    try await FastqTerminalClient.shared.focusSession(session.id)
                } catch {
                    sessions.remove(session.id)
                }
            }
            return
        }
        activateTerminalWindow(windowID: session.terminalWindowID, pid: session.processIdentifier)
    }

    /// Switch Fastq Terminal tab without bringing that app forward (for launcher ↑/↓).
    func selectTerminalTab(_ sessionID: UUID) {
        Task {
            try? await FastqTerminalClient.shared.selectSession(sessionID)
        }
    }

    func quit(_ session: AgentSession) {
        if session.hostedInFastqTerminal {
            Task {
                try? await FastqTerminalClient.shared.quitSession(session.id)
            }
            sessions.remove(session.id)
            return
        }
        if let pid = session.processIdentifier {
            kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        if let windowID = session.terminalWindowID {
            closeTerminalWindow(windowID: windowID)
        }

        sessions.remove(session.id)
    }

    // MARK: - Prompt

    private func composePrompt(prompt: String, attachments: [PromptAttachment]) -> String {
        guard !attachments.isEmpty else { return prompt }
        let lines = attachments.map { attachment in
            "Attachment: \(attachment.path)"
        }
        return prompt + "\n\n" + lines.joined(separator: "\n")
    }

    // MARK: - CLI agents (all run in Fastq Terminal)

    private func terminalCommand(
        kind: AgentToolKind,
        command: String,
        prompt: String,
        model: AgentModelOption,
        projectPath: String,
        extraProjectPaths: [String]
    ) -> String {
        switch kind {
        case .cursorCLI:
            return cursorAgentCommand(command: command, prompt: prompt, model: model, projectPath: projectPath)
        case .claudeCode:
            return claudeCommand(command: command, prompt: prompt, model: model)
        case .codexCLI:
            return codexCommand(
                command: command,
                prompt: prompt,
                model: model,
                projectPath: projectPath,
                extraProjectPaths: extraProjectPaths
            )
        case .grokAgent:
            return grokCommand(command: command, prompt: prompt, model: model, projectPath: projectPath)
        case .openCode:
            return openCodeCommand(command: command, prompt: prompt, model: model)
        }
    }

    private func claudeCommand(command: String, prompt: String, model: AgentModelOption) -> String {
        var parts = [shellEscape(resolvedExecutable(command) ?? command)]
        if model != .auto {
            parts += ["--model", shellEscape(model.cliModelFlag(for: .claudeCode))]
        }
        appendPromptArgument(to: &parts, prompt: prompt)
        return parts.joined(separator: " ")
    }

    private func codexCommand(
        command: String,
        prompt: String,
        model: AgentModelOption,
        projectPath: String,
        extraProjectPaths: [String]
    ) -> String {
        // Full interactive TUI (Ghostty renders the alt screen natively):
        // - `--cd` sets the workspace root explicitly
        // - prompt is injected after boot (see TerminalSession) so the TUI paints first
        var parts = [shellEscape(resolvedExecutable(command) ?? command)]
        parts += ["--cd", shellEscape(projectPath)]
        if model != .auto {
            parts += ["--model", shellEscape(model.cliModelFlag(for: .codexCLI))]
        }
        for extra in extraProjectPaths where extra != projectPath {
            parts += ["--add-dir", shellEscape(extra)]
        }
        _ = prompt // injected post-launch
        return parts.joined(separator: " ")
    }

    private func cursorAgentCommand(
        command: String,
        prompt: String,
        model: AgentModelOption,
        projectPath: String
    ) -> String {
        // Prefer cursor-agent binary; never bare `agent` (clashes with Grok).
        let exe = shellEscape(resolvedExecutable(command) ?? command)
        var parts = [exe]
        parts += ["--workspace", shellEscape(projectPath)]
        if model != .auto {
            parts += ["--model", shellEscape(model.cliModelFlag(for: .cursorCLI))]
        }
        appendPromptArgument(to: &parts, prompt: prompt)
        return parts.joined(separator: " ")
    }

    private func grokCommand(
        command: String,
        prompt: String,
        model: AgentModelOption,
        projectPath: String
    ) -> String {
        var parts = [shellEscape(resolvedExecutable(command) ?? command)]
        parts += ["--cwd", shellEscape(projectPath)]
        if model != .auto {
            parts += ["--model", shellEscape(model.cliModelFlag(for: .grokAgent))]
        }
        appendPromptArgument(to: &parts, prompt: prompt)
        return parts.joined(separator: " ")
    }

    private func openCodeCommand(command: String, prompt: String, model: AgentModelOption) -> String {
        var parts = [shellEscape(resolvedExecutable(command) ?? command)]
        if model != .auto {
            parts += ["--model", shellEscape(model.cliModelFlag(for: .openCode))]
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts += ["--prompt", shellEscape(trimmed)]
        }
        return parts.joined(separator: " ")
    }

    private func appendPromptArgument(to parts: inout [String], prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        parts.append(shellEscape(trimmed))
    }

    // MARK: - Focus / quit helpers (legacy Terminal.app sessions)

    private func activateTerminalWindow(windowID: Int?, pid: pid_t?) {
        if let windowID {
            let script = """
            tell application "Terminal"
                activate
                try
                    set index of window id \(windowID) to 1
                end try
            end tell
            """
            _ = try? runAppleScript(script)
            return
        }

        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else {
            NSWorkspace.shared.launchApplication("Terminal")
        } 
    }

    private func closeTerminalWindow(windowID: Int) {
        let script = """
        tell application "Terminal"
            try
                close window id \(windowID)
            end try
        end tell
        """
        _ = try? runAppleScript(script)
    }

    // MARK: - Utilities

    private func resolvedExecutable(_ command: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        if let detected = ToolPathDetector.resolve(command) {
            return detected
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let home = NSHomeDirectory()
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.grok/bin", "\(home)/.opencode/bin"] {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runAppleScript(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AgentLaunchError.scriptFailed("Could not create AppleScript.")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed."
            throw AgentLaunchError.scriptFailed(message)
        }
        return result.stringValue ?? ""
    }
}

enum AgentLaunchError: LocalizedError {
    case scriptFailed(String)
    case missingProject
    case missingTool

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message): return message
        case .missingProject: return "Choose a project folder first."
        case .missingTool: return "Choose an agent tool first."
        }
    }
}
