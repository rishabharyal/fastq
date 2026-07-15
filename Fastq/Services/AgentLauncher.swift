import Foundation
import AppKit

@MainActor
final class AgentLauncher {
    private let settings: AppSettings
    private let sessions: SessionStore

    init(settings: AppSettings, sessions: SessionStore) {
        self.settings = settings
        self.sessions = sessions
    }

    func launch(
        prompt: String,
        project: ProjectFolder,
        tool: ToolConfig,
        model: AgentModelOption,
        attachments: [PromptAttachment],
        extraProjectPaths: [String] = []
    ) throws -> AgentSession {
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
            let terminal = try sessions.terminals.create(from: CreateSessionRequest(
                sessionID: session.id,
                title: session.title,
                projectName: project.name,
                projectPath: project.path,
                command: commandLine,
                prompt: injectPrompt ? composedPrompt : "",
                tool: tool.kind.rawValue
            ))
            session.processIdentifier = terminal.childPID
            session.status = .running
            sessions.update(session)
            return session
        } catch {
            sessions.remove(session.id)
            throw error
        }
    }

    func focus(_ session: AgentSession) {
        sessions.terminals.select(session.id)
        NotificationCenter.default.post(
            name: .fastqOpenSessionPreview,
            object: session.id
        )
    }

    /// Switch active PTY tab (launcher ↑/↓ while preview is open).
    func selectTerminalTab(_ sessionID: UUID) {
        sessions.terminals.select(sessionID)
    }

    func quit(_ session: AgentSession) {
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

    // MARK: - CLI agents (local PTY)

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
        case .shell:
            return ""
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
        var parts = [shellEscape(resolvedExecutable(command) ?? command)]
        parts += ["--cd", shellEscape(projectPath)]
        if model != .auto {
            parts += ["--model", shellEscape(model.cliModelFlag(for: .codexCLI))]
        }
        for extra in extraProjectPaths where extra != projectPath {
            parts += ["--add-dir", shellEscape(extra)]
        }
        return parts.joined(separator: " ")
    }

    private func cursorAgentCommand(
        command: String,
        prompt: String,
        model: AgentModelOption,
        projectPath: String
    ) -> String {
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
