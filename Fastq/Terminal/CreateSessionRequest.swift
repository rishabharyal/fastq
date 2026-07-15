import Foundation

/// Request to spawn a local agent/shell PTY session inside the launcher.
public struct CreateSessionRequest: Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var title: String
    public var projectName: String
    public var projectPath: String
    public var command: String
    public var prompt: String
    public var tool: String

    public init(
        sessionID: UUID = UUID(),
        title: String,
        projectName: String,
        projectPath: String,
        command: String,
        prompt: String,
        tool: String
    ) {
        self.sessionID = sessionID
        self.title = title
        self.projectName = projectName
        self.projectPath = projectPath
        self.command = command
        self.prompt = prompt
        self.tool = tool
    }
}
