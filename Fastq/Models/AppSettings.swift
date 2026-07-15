import Foundation
import AppKit
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var projects: [ProjectFolder] {
        didSet { save() }
    }

    @Published var tools: [ToolConfig] {
        didSet { save() }
    }

    @Published var defaultToolID: UUID? {
        didSet { save() }
    }

    @Published var defaultModel: AgentModelOption {
        didSet { save() }
    }

    @Published var hotkeyKeyCode: UInt16 {
        didSet { save() }
    }

    @Published var hotkeyModifiers: UInt {
        didSet { save() }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { save() }
    }

    @Published var recentProjectIDs: [UUID] {
        didSet { save() }
    }

    /// Placeholder auth: toggles the footer between "Log in" and the local
    /// macOS profile (initials + full name). Real backend comes later.
    @Published var isLoggedIn: Bool {
        didSet { save() }
    }

    /// Submitted prompts, oldest → newest (recalled with ↑ in the launcher).
    @Published var promptHistory: [String] {
        didSet { save() }
    }

    /// Last-used launcher mode (⌘1 chat / ⌘2 agent) — restored on open.
    @Published var launcherMode: LauncherMode {
        didSet { save() }
    }

    @Published var chatProvider: ChatProvider {
        didSet { save() }
    }

    @Published var anthropicAPIKey: String {
        didSet { save() }
    }

    @Published var openAIAPIKey: String {
        didSet { save() }
    }

    @Published var anthropicChatModel: String {
        didSet { save() }
    }

    @Published var openAIChatModel: String {
        didSet { save() }
    }

    /// Model to send for the active chat provider.
    var chatModel: String {
        switch chatProvider {
        case .anthropic: return anthropicChatModel
        case .openai: return openAIChatModel
        }
    }

    /// API key for the active chat provider.
    var chatAPIKey: String {
        switch chatProvider {
        case .anthropic: return anthropicAPIKey
        case .openai: return openAIAPIKey
        }
    }

    private let defaultsKey = "fastq.settings.v1"
    private let maxRecents = 8

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            projects = decoded.projects
            tools = Self.normalizedTools(decoded.tools)
            defaultToolID = decoded.defaultToolID
            defaultModel = decoded.defaultModel
            // Migrate the old ⌘⌥K default to ⌘↩; custom bindings are kept.
            if decoded.hotkeyKeyCode == HotkeyShortcut.legacyDefaultKeyCode,
               decoded.hotkeyModifiers == HotkeyShortcut.legacyDefaultModifiers {
                hotkeyKeyCode = HotkeyShortcut.defaultKeyCode
                hotkeyModifiers = HotkeyShortcut.defaultModifiers
            } else {
                hotkeyKeyCode = decoded.hotkeyKeyCode
                hotkeyModifiers = decoded.hotkeyModifiers
            }
            hasCompletedOnboarding = decoded.hasCompletedOnboarding
            recentProjectIDs = decoded.recentProjectIDs.filter { id in
                decoded.projects.contains(where: { $0.id == id })
            }
            isLoggedIn = decoded.isLoggedIn
            promptHistory = decoded.promptHistory
            launcherMode = decoded.launcherMode
            chatProvider = decoded.chatProvider
            anthropicAPIKey = decoded.anthropicAPIKey
            openAIAPIKey = decoded.openAIAPIKey
            anthropicChatModel = decoded.anthropicChatModel
            openAIChatModel = decoded.openAIChatModel
            // Drop legacy Cursor GUI default if it pointed at a removed tool.
            if let defaultToolID, !tools.contains(where: { $0.id == defaultToolID && $0.enabled }) {
                self.defaultToolID = tools.first(where: \.enabled)?.id
                    ?? tools.first(where: { $0.kind == .claudeCode })?.id
            }
        } else {
            let defaultTools = AgentToolKind.allCases.map { ToolConfig(kind: $0) }
            projects = []
            tools = defaultTools
            defaultToolID = defaultTools.first(where: { $0.kind == .claudeCode })?.id
            defaultModel = .auto
            // Default ⌘↩
            hotkeyKeyCode = HotkeyShortcut.defaultKeyCode
            hotkeyModifiers = HotkeyShortcut.defaultModifiers
            hasCompletedOnboarding = false
            recentProjectIDs = []
            isLoggedIn = false
            promptHistory = []
            launcherMode = .agent
            chatProvider = .anthropic
            anthropicAPIKey = ""
            openAIAPIKey = ""
            anthropicChatModel = ChatProvider.anthropic.defaultModel
            openAIChatModel = ChatProvider.openai.defaultModel
        }
    }

    /// Remember a submitted prompt for ↑-recall (dedupes repeats, caps at 50).
    func recordPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, promptHistory.last != trimmed else { return }
        promptHistory.append(trimmed)
        if promptHistory.count > 50 {
            promptHistory.removeFirst(promptHistory.count - 50)
        }
    }

    var enabledTools: [ToolConfig] {
        tools.filter(\.enabled)
    }

    var needsSetup: Bool {
        !hasCompletedOnboarding || projects.isEmpty || enabledTools.isEmpty
    }

    func addProject(path: String) {
        let folder = ProjectFolder(path: path)
        guard !projects.contains(where: { $0.path == folder.path }) else { return }
        projects.append(folder)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func addProjectReturning(_ path: String) -> ProjectFolder? {
        if let existing = projects.first(where: { $0.path == path }) {
            return existing
        }
        let folder = ProjectFolder(path: path)
        projects.append(folder)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return projects.first(where: { $0.path == path })
    }

    func removeProject(_ project: ProjectFolder) {
        projects.removeAll { $0.id == project.id }
        recentProjectIDs.removeAll { $0 == project.id }
    }

    func markProjectUsed(_ project: ProjectFolder) {
        recentProjectIDs.removeAll { $0 == project.id }
        recentProjectIDs.insert(project.id, at: 0)
        if recentProjectIDs.count > maxRecents {
            recentProjectIDs = Array(recentProjectIDs.prefix(maxRecents))
        }
    }

    func tool(for id: UUID?) -> ToolConfig? {
        guard let id else { return enabledTools.first }
        return tools.first(where: { $0.id == id && $0.enabled }) ?? enabledTools.first
    }

    func applyDetectedToolPaths(_ detections: [DetectedToolPath]) {
        for detection in detections {
            guard let index = tools.firstIndex(where: { $0.kind == detection.kind }) else { continue }
            if let path = detection.path {
                tools[index].commandPath = path
                tools[index].enabled = true
            } else {
                tools[index].enabled = false
            }
        }

        if defaultToolID == nil || !(tools.contains { $0.id == defaultToolID && $0.enabled }) {
            defaultToolID = tools.first(where: \.enabled)?.id
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
    }

    /// Ensure every supported CLI tool exists; drop removed kinds (e.g. Cursor GUI).
    private static func normalizedTools(_ existing: [ToolConfig]) -> [ToolConfig] {
        var byKind: [AgentToolKind: ToolConfig] = [:]
        for tool in existing {
            byKind[tool.kind] = tool
        }
        return AgentToolKind.allCases.map { kind in
            if var existing = byKind[kind] {
                // Migrate old Cursor CLI default that pointed at the GUI binary.
                if kind == .cursorCLI,
                   existing.commandPath.contains("/cursor"),
                   !existing.commandPath.contains("cursor-agent"),
                   !existing.commandPath.hasSuffix("/agent") {
                    existing.commandPath = kind.defaultCommand
                }
                existing.displayName = kind.displayName
                return existing
            }
            return ToolConfig(kind: kind)
        }
    }

    private func save() {
        let payload = PersistedSettings(
            projects: projects,
            tools: tools,
            defaultToolID: defaultToolID,
            defaultModel: defaultModel,
            hotkeyKeyCode: hotkeyKeyCode,
            hotkeyModifiers: hotkeyModifiers,
            hasCompletedOnboarding: hasCompletedOnboarding,
            recentProjectIDs: recentProjectIDs,
            isLoggedIn: isLoggedIn,
            promptHistory: promptHistory,
            launcherMode: launcherMode,
            chatProvider: chatProvider,
            anthropicAPIKey: anthropicAPIKey,
            openAIAPIKey: openAIAPIKey,
            anthropicChatModel: anthropicChatModel,
            openAIChatModel: openAIChatModel
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

private struct PersistedSettings: Codable {
    var projects: [ProjectFolder]
    var tools: [ToolConfig]
    var defaultToolID: UUID?
    var defaultModel: AgentModelOption
    var hotkeyKeyCode: UInt16
    var hotkeyModifiers: UInt
    var hasCompletedOnboarding: Bool
    var recentProjectIDs: [UUID]
    var isLoggedIn: Bool
    var promptHistory: [String]
    var launcherMode: LauncherMode
    var chatProvider: ChatProvider
    var anthropicAPIKey: String
    var openAIAPIKey: String
    var anthropicChatModel: String
    var openAIChatModel: String

    enum CodingKeys: String, CodingKey {
        case projects, tools, defaultToolID, defaultModel
        case hotkeyKeyCode, hotkeyModifiers, hasCompletedOnboarding, recentProjectIDs
        case isLoggedIn, promptHistory
        case launcherMode, chatProvider, anthropicAPIKey, openAIAPIKey
        case anthropicChatModel, openAIChatModel
    }

    init(
        projects: [ProjectFolder],
        tools: [ToolConfig],
        defaultToolID: UUID?,
        defaultModel: AgentModelOption,
        hotkeyKeyCode: UInt16,
        hotkeyModifiers: UInt,
        hasCompletedOnboarding: Bool,
        recentProjectIDs: [UUID],
        isLoggedIn: Bool,
        promptHistory: [String],
        launcherMode: LauncherMode,
        chatProvider: ChatProvider,
        anthropicAPIKey: String,
        openAIAPIKey: String,
        anthropicChatModel: String,
        openAIChatModel: String
    ) {
        self.projects = projects
        self.tools = tools
        self.defaultToolID = defaultToolID
        self.defaultModel = defaultModel
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.recentProjectIDs = recentProjectIDs
        self.isLoggedIn = isLoggedIn
        self.promptHistory = promptHistory
        self.launcherMode = launcherMode
        self.chatProvider = chatProvider
        self.anthropicAPIKey = anthropicAPIKey
        self.openAIAPIKey = openAIAPIKey
        self.anthropicChatModel = anthropicChatModel
        self.openAIChatModel = openAIChatModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([ProjectFolder].self, forKey: .projects)
        // Lossy tool decode so removed kinds (e.g. "cursor") don't wipe settings.
        let rawTools = try container.decode([FlexibleToolConfig].self, forKey: .tools)
        tools = rawTools.compactMap(\.asToolConfig)
        defaultToolID = try container.decodeIfPresent(UUID.self, forKey: .defaultToolID)
        defaultModel = try container.decode(AgentModelOption.self, forKey: .defaultModel)
        hotkeyKeyCode = try container.decode(UInt16.self, forKey: .hotkeyKeyCode)
        hotkeyModifiers = try container.decode(UInt.self, forKey: .hotkeyModifiers)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
            ?? projects.isEmpty
        recentProjectIDs = try container.decodeIfPresent([UUID].self, forKey: .recentProjectIDs) ?? []
        isLoggedIn = try container.decodeIfPresent(Bool.self, forKey: .isLoggedIn) ?? false
        promptHistory = try container.decodeIfPresent([String].self, forKey: .promptHistory) ?? []
        launcherMode = try container.decodeIfPresent(LauncherMode.self, forKey: .launcherMode) ?? .agent
        chatProvider = try container.decodeIfPresent(ChatProvider.self, forKey: .chatProvider) ?? .anthropic
        anthropicAPIKey = try container.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? ""
        openAIAPIKey = try container.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? ""
        anthropicChatModel = try container.decodeIfPresent(String.self, forKey: .anthropicChatModel)
            ?? ChatProvider.anthropic.defaultModel
        openAIChatModel = try container.decodeIfPresent(String.self, forKey: .openAIChatModel)
            ?? ChatProvider.openai.defaultModel
    }
}

/// Decodes tool rows even when `kind` is a removed legacy value.
private struct FlexibleToolConfig: Decodable {
    var id: UUID
    var kind: String
    var enabled: Bool
    var commandPath: String
    var displayName: String

    var asToolConfig: ToolConfig? {
        guard let kind = AgentToolKind(rawValue: kind) else { return nil }
        return ToolConfig(
            id: id,
            kind: kind,
            enabled: enabled,
            commandPath: commandPath,
            displayName: displayName
        )
    }
}
