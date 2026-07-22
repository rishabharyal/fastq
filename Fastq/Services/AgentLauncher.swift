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

    /// Starts a headless chat session (no terminal) and mirrors it as an
    /// `AgentSession` row for the launcher list.
    func launch(
        prompt: String,
        context: AgentLaunchContext,
        tool: ToolConfig,
        model: AgentModelOption,
        attachments: [PromptAttachment]
    ) throws -> AgentSession {
        let cleaned = Self.stripTaskMentionTokens(from: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText: String
        if cleaned.isEmpty, let task = context.linkedTasks.first {
            displayText = "Work on: \(task.title)"
        } else {
            displayText = cleaned
        }

        // Workspace/project/task context ships as a refs.md file the agent
        // reads, keeping the visible prompt short.
        let composedPrompt: String
        if let refsURL = try? Self.writeRefs(context: context) {
            var parts = [
                "Read \(refsURL.path) first — it describes the workspace, the project folders, and any linked task(s) with full details."
            ]
            var request: [String] = []
            if cleaned.isEmpty, !context.linkedTasks.isEmpty {
                request.append(context.linkedTasks.count == 1
                    ? "Please work on the linked task described in that file."
                    : "Please work on the linked tasks described in that file.")
            } else if !cleaned.isEmpty {
                request.append(cleaned)
            }
            request.append(contentsOf: attachments.map { "Attachment: \($0.path)" })
            if !request.isEmpty {
                parts.append("## User request\n" + request.joined(separator: "\n\n"))
            }
            composedPrompt = parts.joined(separator: "\n\n")
        } else {
            composedPrompt = composePrompt(prompt: prompt, attachments: attachments, context: context)
        }

        AgentChatStore.shared.bind(settings: settings)
        let chat = try AgentChatStore.shared.startSession(
            tool: tool.kind,
            projectName: context.projectName,
            projectPath: context.projectPath,
            model: model,
            prompt: composedPrompt,
            displayText: displayText,
            attachments: attachments.map(\.name)
        )

        let session = AgentSession(
            id: chat.id,
            tool: tool.kind,
            projectName: context.projectName,
            projectPath: context.projectPath,
            promptPreview: displayText,
            model: model,
            startedAt: Date(),
            processIdentifier: nil,
            terminalWindowID: nil,
            status: .running,
            isChat: true
        )
        sessions.add(session)
        return session
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
        if session.isChat {
            AgentChatStore.shared.remove(sessionID: session.id)
        }
        sessions.remove(session.id)
    }

    // MARK: - refs.md

    /// Writes the launch context to Application Support/Fastq/refs/<id>/refs.md.
    static func writeRefs(context: AgentLaunchContext) throws -> URL {
        var lines: [String] = [
            "# Fastq session context",
            "",
            "## Workspace",
            "Workspace: \(context.workspaceName)",
            "Active project: \(context.projectName)",
            "Project folder (your working directory): \(context.projectPath)",
            "",
        ]
        if context.siblings.isEmpty {
            lines.append("Related projects in this workspace: (none)")
        } else {
            lines.append("## Related projects in this workspace")
            for sibling in context.siblings {
                lines.append("- \(sibling.name) — \(sibling.path ?? "no local folder linked")")
            }
        }
        if !context.linkedTasks.isEmpty {
            lines.append("")
            lines.append("## Linked task\(context.linkedTasks.count == 1 ? "" : "s")")
            for task in context.linkedTasks {
                lines.append("")
                lines.append("### \(task.title)")
                lines.append("Task ID: \(task.id)")
                if let column = task.columnName, !column.isEmpty { lines.append("Column: \(column)") }
                if let status = task.status, !status.isEmpty { lines.append("Status: \(status)") }
                if let priority = task.priority, !priority.isEmpty { lines.append("Priority: \(priority)") }
                if let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    lines.append("")
                    lines.append("Description:")
                    lines.append(description)
                }
            }
        }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fastq/refs/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("refs.md")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
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
