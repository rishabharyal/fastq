import Foundation
import AppKit

struct AgentWorkspaceSibling: Equatable {
    var name: String
    var path: String?
}

struct AgentLinkedTask: Equatable {
    var id: String
    var title: String
    var description: String?
    var columnName: String?
    var status: String?
    var priority: String?
}

struct AgentLaunchContext: Equatable {
    var workspaceName: String
    var projectName: String
    var projectPath: String
    var siblings: [AgentWorkspaceSibling]
    var linkedTasks: [AgentLinkedTask]
}

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
        context: AgentLaunchContext,
        tool: ToolConfig,
        model: AgentModelOption,
        attachments: [PromptAttachment]
    ) throws -> AgentSession {
        let composedPrompt = composePrompt(
            prompt: prompt,
            attachments: attachments,
            context: context
        )
        let extraPaths = context.siblings.compactMap(\.path).filter { $0 != context.projectPath }
        var session = AgentSession(
            id: UUID(),
            tool: tool.kind,
            projectName: context.projectName,
            projectPath: context.projectPath,
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
                projectPath: context.projectPath,
                extraProjectPaths: extraPaths
            )
            // Codex boots a cleaner full TUI when the prompt is typed after start.
            let injectPrompt = tool.kind == .codexCLI
            let terminal = try sessions.terminals.create(from: CreateSessionRequest(
                sessionID: session.id,
                title: session.title,
                projectName: context.projectName,
                projectPath: context.projectPath,
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

    private func composePrompt(
        prompt: String,
        attachments: [PromptAttachment],
        context: AgentLaunchContext
    ) -> String {
        var sections: [String] = []

        var workspaceLines = [
            "## Fastq workspace context",
            "Workspace: \(context.workspaceName)",
            "Active project: \(context.projectName) (\(context.projectPath))",
        ]
        if context.siblings.isEmpty {
            workspaceLines.append("Related projects in this workspace: (none)")
        } else {
            workspaceLines.append("Related projects in this workspace:")
            for sibling in context.siblings {
                let pathNote = sibling.path ?? "no local folder"
                workspaceLines.append("- \(sibling.name) (\(pathNote))")
            }
        }
        sections.append(workspaceLines.joined(separator: "\n"))

        if !context.linkedTasks.isEmpty {
            var taskLines = ["## Linked task"]
            for task in context.linkedTasks {
                taskLines.append("Title: \(task.title)")
                if let column = task.columnName, !column.isEmpty {
                    taskLines.append("Column: \(column)")
                }
                if let status = task.status, !status.isEmpty {
                    taskLines.append("Status: \(status)")
                }
                if let priority = task.priority, !priority.isEmpty {
                    taskLines.append("Priority: \(priority)")
                }
                if let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    taskLines.append("Description:\n\(description)")
                }
                taskLines.append("")
            }
            sections.append(taskLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let cleanedPrompt = Self.stripTaskMentionTokens(from: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var requestParts: [String] = []
        if cleanedPrompt.isEmpty, !context.linkedTasks.isEmpty {
            requestParts.append(
                context.linkedTasks.count == 1
                    ? "Please work on the linked task."
                    : "Please work on the linked tasks."
            )
        } else if !cleanedPrompt.isEmpty {
            requestParts.append(cleanedPrompt)
        }
        if !attachments.isEmpty {
            requestParts.append(contentsOf: attachments.map { "Attachment: \($0.path)" })
        }
        if !requestParts.isEmpty {
            sections.append("## User request\n" + requestParts.joined(separator: "\n\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    /// Remove `#task:<id>` tokens so the agent sees prose + linked-task context.
    static func stripTaskMentionTokens(from text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "#task:[A-Za-z0-9\\-]+")
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
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
    case missingFolder
    case missingTool
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message): return message
        case .missingProject: return "Choose a Fastplay project first."
        case .missingFolder: return "Link a local folder to this project before launching an agent."
        case .missingTool: return "Choose an agent tool first."
        case .notSignedIn: return "Sign in to Fastplay to launch agents on a project."
        }
    }
}
