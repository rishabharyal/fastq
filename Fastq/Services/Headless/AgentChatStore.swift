import Foundation
import Combine
import AppKit

/// The user is being asked something mid-run (permission or clarifying
/// question). Holds the continuation that resumes the CLI.
struct PendingInteraction: Identifiable {
    enum Kind {
        case permission(toolName: String, summary: String, input: AnyJSON)
        case question([AskQuestion], original: AnyJSON)
    }

    let id = UUID()
    /// Transcript item rendered for this interaction.
    let itemID: UUID
    let kind: Kind
    let respond: (BridgeResponse) -> Void
}

/// One headless agent conversation (Claude or Cursor) — transcript,
/// engine process, and mid-run interactions.
@MainActor
final class AgentChatSession: ObservableObject, Identifiable {
    let id: UUID
    let tool: AgentToolKind
    let projectName: String
    let projectPath: String
    var model: AgentModelOption

    @Published var items: [AgentChatItem] = []
    @Published var phase: Phase = .idle
    @Published var statusLine: String?
    @Published var pending: PendingInteraction?
    @Published var costUSD: Double?
    /// Cursor only: prompts waiting for the current run to finish
    /// (Claude queues mid-turn messages inside its persistent process).
    @Published var queuedPrompts: [String] = []

    var engineSessionID: String?
    var runner: HeadlessProcessRunner?
    /// Bridge token for the currently running turn.
    var bridgeToken: String?
    /// Stop was requested — render the interrupted turn as "Stopped".
    var expectingInterrupt = false

    enum Phase: String, Codable {
        case idle, running, waitingForUser, done, failed
    }

    init(
        id: UUID = UUID(),
        tool: AgentToolKind,
        projectName: String,
        projectPath: String,
        model: AgentModelOption
    ) {
        self.id = id
        self.tool = tool
        self.projectName = projectName
        self.projectPath = projectPath
        self.model = model
    }

    var isBusy: Bool { phase == .running || phase == .waitingForUser }

    var title: String {
        for item in items {
            if case .user(let text, _) = item.kind, !text.isEmpty {
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
                return firstLine.count > 48 ? String(firstLine.prefix(45)) + "…" : firstLine
            }
        }
        return "\(tool.shortName) · \(projectName)"
    }

    // MARK: - Transcript mutation

    func appendUser(text: String, attachments: [String]) {
        items.append(AgentChatItem(kind: .user(text: text, attachments: attachments)))
    }

    func apply(_ event: AgentEngineEvent) {
        switch event {
        case .sessionStarted(let engineSessionID, _):
            if !engineSessionID.isEmpty {
                self.engineSessionID = engineSessionID
            }
            statusLine = "Thinking…"

        case .textDelta(let delta):
            if case .assistantText(let existing) = items.last?.kind, isStreamingText {
                items[items.count - 1].kind = .assistantText(existing + delta)
            } else {
                items.append(AgentChatItem(kind: .assistantText(delta)))
                isStreamingText = true
            }
            statusLine = nil

        case .assistantText(let text, let key):
            // Claude re-sends earlier blocks in every message snapshot —
            // apply each keyed block once.
            if let key {
                guard !appliedTextKeys.contains(key) else { break }
                appliedTextKeys.insert(key)
            }
            // Canonical block — replace the streamed accumulation.
            if isStreamingText, case .assistantText = items.last?.kind {
                items[items.count - 1].kind = .assistantText(text)
            } else if !text.isEmpty {
                items.append(AgentChatItem(kind: .assistantText(text)))
            }
            isStreamingText = false
            statusLine = nil

        case .toolStarted(let id, let name, let summary, let isSubagent):
            guard !knownToolIDs.contains(id) else { break }
            knownToolIDs.insert(id)
            isStreamingText = false
            let record = ToolCallRecord(
                id: id,
                name: ClaudeHeadlessEngine.toolDisplayName(name),
                summary: summary,
                startedAt: Date(),
                isSubagent: isSubagent
            )
            if case .toolCalls(var calls) = items.last?.kind {
                calls.append(record)
                items[items.count - 1].kind = .toolCalls(calls)
            } else {
                items.append(AgentChatItem(kind: .toolCalls([record])))
            }
            statusLine = "Running \(record.name)…"

        case .toolFinished(let id, let ok):
            for index in items.indices.reversed() {
                guard case .toolCalls(var calls) = items[index].kind,
                      let callIndex = calls.firstIndex(where: { $0.id == id }) else { continue }
                calls[callIndex].finishedAt = Date()
                calls[callIndex].ok = ok
                items[index].kind = .toolCalls(calls)
                break
            }
            statusLine = "Thinking…"

        case .thinking:
            if statusLine == nil || statusLine?.hasPrefix("Running") == false {
                statusLine = "Thinking…"
            }

        case .retrying(let attempt, let reason):
            statusLine = "Retrying (\(attempt)) — \(reason)"

        case .finished(let ok, let resultText, let cost, let durationMs):
            isStreamingText = false
            statusLine = nil
            if let cost {
                costUSD = (costUSD ?? 0) + cost
            }
            if expectingInterrupt {
                expectingInterrupt = false
                items.append(AgentChatItem(kind: .result(RunResultRecord(
                    ok: true, text: "", costUSD: cost, durationMs: durationMs
                ))))
                items.append(AgentChatItem(kind: .error("Stopped by you.")))
                phase = .done
                break
            }
            // The final result text duplicates the last assistant block —
            // only surface it when it adds something (errors, empty stream).
            if !ok {
                items.append(AgentChatItem(kind: .result(RunResultRecord(
                    ok: false, text: resultText, costUSD: cost, durationMs: durationMs
                ))))
            } else if !hasAssistantText {
                items.append(AgentChatItem(kind: .assistantText(resultText)))
            } else {
                items.append(AgentChatItem(kind: .result(RunResultRecord(
                    ok: true, text: "", costUSD: cost, durationMs: durationMs
                ))))
            }
            phase = ok ? .done : .failed

        case .processFailed(let message):
            isStreamingText = false
            statusLine = nil
            items.append(AgentChatItem(kind: .error(message)))
            phase = .failed
        }
    }

    private var isStreamingText = false
    /// Dedupe state for Claude's snapshot-style assistant events.
    private var appliedTextKeys: Set<String> = []
    private var knownToolIDs: Set<String> = []

    private var hasAssistantText: Bool {
        items.contains {
            if case .assistantText(let text) = $0.kind { return !text.isEmpty }
            return false
        }
    }
}

/// Owns all agent chat sessions: spawning runs, routing bridge requests,
/// persistence across launches.
@MainActor
final class AgentChatStore: ObservableObject {
    static let shared = AgentChatStore()

    @Published private(set) var sessions: [AgentChatSession] = []

    /// Ask-before-actions default; persisted.
    @Published var permissionPreset: AgentPermissionPreset {
        didSet {
            UserDefaults.standard.set(permissionPreset.rawValue, forKey: presetKey)
        }
    }

    private let presetKey = "fastq.agent.permissionPreset.v1"
    private var settings: AppSettings?

    private init() {
        let raw = UserDefaults.standard.string(forKey: presetKey) ?? ""
        permissionPreset = AgentPermissionPreset(rawValue: raw) ?? .askMe
        restore()
    }

    func bind(settings: AppSettings) {
        self.settings = settings
    }

    func session(id: UUID) -> AgentChatSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Creates a session and starts its first turn.
    @discardableResult
    func startSession(
        tool: AgentToolKind,
        projectName: String,
        projectPath: String,
        model: AgentModelOption,
        prompt: String,
        displayText: String,
        attachments: [String]
    ) throws -> AgentChatSession {
        guard HeadlessToolResolver.resolve(tool, settings: settings) != nil else {
            throw AgentLaunchError.scriptFailed("\(tool.displayName) CLI not found. Install it or set its path in Settings → Tools.")
        }
        let session = AgentChatSession(
            id: UUID(),
            tool: tool,
            projectName: projectName,
            projectPath: projectPath,
            model: model
        )
        sessions.insert(session, at: 0)
        session.appendUser(text: displayText, attachments: attachments)
        runTurn(session: session, prompt: prompt)
        persist()
        return session
    }

    /// Sends a follow-up. Claude: written straight into the persistent
    /// process (the CLI queues it if a turn is running). Cursor: queued
    /// client-side while busy, flushed when the run finishes.
    func sendFollowUp(sessionID: UUID, prompt: String, attachments: [String]) {
        guard let session = session(id: sessionID) else { return }
        var fullPrompt = prompt
        if !attachments.isEmpty {
            fullPrompt += "\n\n" + attachments.map { "Attachment: \($0)" }.joined(separator: "\n")
        }
        session.appendUser(text: prompt, attachments: attachments.map { ($0 as NSString).lastPathComponent })

        if session.isBusy, session.tool == .cursorCLI {
            session.queuedPrompts.append(fullPrompt)
            persist()
            return
        }
        runTurn(session: session, prompt: fullPrompt)
        persist()
    }

    /// Cursor: run the next queued prompt once a turn ends.
    func flushQueueIfNeeded(session: AgentChatSession) {
        guard !session.isBusy, !session.queuedPrompts.isEmpty else { return }
        let next = session.queuedPrompts.removeFirst()
        runTurn(session: session, prompt: next)
    }

    func stop(sessionID: UUID) {
        guard let session = session(id: sessionID) else { return }
        // Unblock a pending approval first so the CLI can wind down.
        if let pending = session.pending {
            pending.respond(.deny(message: "The user stopped this run."))
            session.pending = nil
        }
        session.queuedPrompts = []
        if let runner = session.runner, runner.usesStdin, session.isBusy {
            // Documented stdin control protocol: abort the turn, keep the
            // session process alive.
            session.expectingInterrupt = true
            if !runner.send(line: ClaudeHeadlessEngine.interruptLine()) {
                session.expectingInterrupt = false
                runner.terminate()
            }
        } else {
            session.runner?.terminate()
        }
    }

    func remove(sessionID: UUID) {
        guard let session = session(id: sessionID) else { return }
        if let pending = session.pending {
            pending.respond(.deny(message: "The user closed this session."))
            session.pending = nil
        }
        session.queuedPrompts = []
        session.runner?.closeInput()
        session.runner?.terminate()
        if let token = session.bridgeToken {
            PermissionBridge.shared.unregister(token: token)
        }
        sessions.removeAll { $0.id == sessionID }
        persist()
    }

    // MARK: - Turn execution

    private func runTurn(session: AgentChatSession, prompt: String) {
        // Claude: one persistent process per conversation — later turns are
        // just stdin writes (mid-turn writes queue inside the CLI).
        if session.tool == .claudeCode,
           let runner = session.runner, runner.isRunning, runner.usesStdin {
            if let line = ClaudeHeadlessEngine.userMessageLine(prompt), runner.send(line: line) {
                session.phase = .running
                session.statusLine = "Thinking…"
                return
            }
            // Pipe broken — fall through and respawn with --resume.
            session.runner = nil
        }

        session.phase = .running
        session.statusLine = "Starting \(session.tool.shortName)…"

        guard let executable = HeadlessToolResolver.resolve(session.tool, settings: settings) else {
            session.apply(.processFailed("\(session.tool.displayName) CLI not found."))
            return
        }

        let arguments: [String]
        let interactive: Bool
        switch session.tool {
        case .claudeCode:
            let port = PermissionBridge.shared.ensureStarted()
            let token = UUID().uuidString
            session.bridgeToken = token
            registerBridgeHandler(session: session, token: token)
            arguments = ClaudeHeadlessEngine.arguments(
                model: session.model,
                resumeSessionID: session.engineSessionID,
                preset: permissionPreset,
                bridgePort: port > 0 ? port : nil,
                bridgeToken: port > 0 ? token : nil
            )
            interactive = true
        case .cursorCLI:
            arguments = CursorHeadlessEngine.arguments(
                prompt: prompt,
                model: session.model,
                resumeSessionID: session.engineSessionID,
                preset: permissionPreset
            )
            interactive = false
        default:
            session.apply(.processFailed("\(session.tool.displayName) is not supported in headless mode."))
            return
        }

        let runner = HeadlessProcessRunner()
        session.runner = runner
        let tool = session.tool

        runner.onLine = { [weak self, weak session] line in
            guard let session else { return }
            let events = tool == .claudeCode
                ? ClaudeHeadlessEngine.parse(line: line)
                : CursorHeadlessEngine.parse(line: line)
            for event in events {
                session.apply(event)
                if case .finished = event {
                    self?.flushQueueIfNeeded(session: session)
                    self?.persist()
                }
            }
        }
        runner.onExit = { [weak self, weak session] status, stderrTail in
            guard let session else { return }
            if let token = session.bridgeToken {
                PermissionBridge.shared.unregister(token: token)
                session.bridgeToken = nil
            }
            session.pending = nil
            session.runner = nil
            // A `result` event normally lands before exit; only synthesize
            // a failure when the process died without one.
            if session.phase == .running || session.phase == .waitingForUser {
                if status == 143 || status == 130 {
                    session.apply(.finished(ok: true, resultText: "Stopped.", costUSD: nil, durationMs: nil))
                } else {
                    let detail = stderrTail.isEmpty ? "exit \(status)" : stderrTail
                    session.apply(.processFailed(headlineError(from: detail)))
                }
            }
            self?.flushQueueIfNeeded(session: session)
            self?.persist()
        }

        do {
            try runner.start(
                executable: executable,
                arguments: arguments,
                currentDirectory: session.projectPath,
                interactive: interactive
            )
            if interactive {
                if let line = ClaudeHeadlessEngine.userMessageLine(prompt) {
                    runner.send(line: line)
                }
            }
        } catch {
            session.apply(.processFailed(error.localizedDescription))
        }
    }

    // MARK: - Bridge routing

    private func registerBridgeHandler(session: AgentChatSession, token: String) {
        PermissionBridge.shared.register(token: token) { [weak self, weak session] request in
            guard let self, let session else {
                return .deny(message: "Session is gone.")
            }
            return await self.presentInteraction(session: session, request: request)
        }
    }

    /// Turns a bridge request into a transcript card + suspends until the
    /// user decides.
    private func presentInteraction(session: AgentChatSession, request: BridgeRequest) async -> BridgeResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<BridgeResponse, Never>) in
            let itemID: UUID
            let kind: PendingInteraction.Kind

            if request.toolName == "AskUserQuestion", let questions = Self.parseQuestions(request.input) {
                let item = AgentChatItem(kind: .question(QuestionRecord(questions: questions)))
                itemID = item.id
                session.items.append(item)
                kind = .question(questions, original: request.input)
            } else {
                let inputDict = request.input.objectValue.map { obj -> [String: Any] in
                    obj.mapValues { Self.anyValue($0) }
                } ?? [:]
                let summary = ClaudeHeadlessEngine.toolSummary(name: request.toolName, input: inputDict)
                let record = PermissionRecord(
                    toolName: ClaudeHeadlessEngine.toolDisplayName(request.toolName),
                    summary: summary
                )
                let item = AgentChatItem(kind: .permission(record))
                itemID = item.id
                session.items.append(item)
                kind = .permission(toolName: request.toolName, summary: summary, input: request.input)
            }

            session.phase = .waitingForUser
            session.statusLine = nil
            var resumed = false
            session.pending = PendingInteraction(itemID: itemID, kind: kind) { [weak session] response in
                guard !resumed else { return }
                resumed = true
                session?.pending = nil
                if let session, session.phase == .waitingForUser {
                    session.phase = .running
                    session.statusLine = "Thinking…"
                }
                continuation.resume(returning: response)
            }
            NSSound.beep()
        }
    }

    private static func parseQuestions(_ input: AnyJSON) -> [AskQuestion]? {
        guard let list = input["questions"]?.arrayValue else { return nil }
        let questions: [AskQuestion] = list.compactMap { q in
            guard let text = q["question"]?.stringValue else { return nil }
            let options = (q["options"]?.arrayValue ?? []).compactMap { opt -> AskQuestionOption? in
                guard let label = opt["label"]?.stringValue else { return nil }
                return AskQuestionOption(label: label, description: opt["description"]?.stringValue)
            }
            return AskQuestion(
                question: text,
                header: q["header"]?.stringValue,
                options: options,
                multiSelect: q["multiSelect"]?.boolValue ?? false
            )
        }
        return questions.isEmpty ? nil : questions
    }

    private static func anyValue(_ json: AnyJSON) -> Any {
        switch json {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(anyValue)
        case .object(let o): return o.mapValues(anyValue)
        }
    }

    // MARK: - Interaction responses (called from UI)

    func answerQuestion(session: AgentChatSession, answers: [String: String]) {
        guard let pending = session.pending,
              case .question(let questions, let original) = pending.kind else { return }
        // Mark the card answered.
        if let index = session.items.firstIndex(where: { $0.id == pending.itemID }),
           case .question(var record) = session.items[index].kind {
            record.answers = answers
            record.answered = true
            session.items[index].kind = .question(record)
        }
        // Response contract: pass the original questions back plus
        // {question text: chosen label} answers.
        var updated = original.objectValue ?? [:]
        updated["answers"] = .object(answers.mapValues { .string($0) })
        if updated["questions"] == nil, case .object(let obj) = original, let q = obj["questions"] {
            updated["questions"] = q
        }
        pending.respond(.allow(updatedInput: .object(updated)))
        persist()
    }

    func resolvePermission(session: AgentChatSession, allow: Bool) {
        guard let pending = session.pending,
              case .permission(_, _, let input) = pending.kind else { return }
        if let index = session.items.firstIndex(where: { $0.id == pending.itemID }),
           case .permission(var record) = session.items[index].kind {
            record.allowed = allow
            session.items[index].kind = .permission(record)
        }
        pending.respond(allow
            ? .allow(updatedInput: input)
            : .deny(message: "The user declined this action."))
        persist()
    }

    // MARK: - Persistence

    private struct PersistedSession: Codable {
        var id: UUID
        var tool: AgentToolKind
        var projectName: String
        var projectPath: String
        var model: AgentModelOption
        var engineSessionID: String?
        var items: [AgentChatItem]
        var phase: AgentChatSession.Phase
        var costUSD: Double?
    }

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fastq", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent-chats.json")
    }

    func persist() {
        let snapshot = sessions.prefix(30).map { s in
            PersistedSession(
                id: s.id,
                tool: s.tool,
                projectName: s.projectName,
                projectPath: s.projectPath,
                model: s.model,
                engineSessionID: s.engineSessionID,
                items: s.items,
                phase: s.isBusy ? .idle : s.phase,
                costUSD: s.costUSD
            )
        }
        guard let data = try? JSONEncoder().encode(Array(snapshot)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              let persisted = try? JSONDecoder().decode([PersistedSession].self, from: data) else {
            return
        }
        sessions = persisted.map { p in
            let session = AgentChatSession(
                id: p.id,
                tool: p.tool,
                projectName: p.projectName,
                projectPath: p.projectPath,
                model: p.model
            )
            session.engineSessionID = p.engineSessionID
            session.items = p.items
            session.phase = p.phase == .idle ? .done : p.phase
            session.costUSD = p.costUSD
            return session
        }
    }
}

private func headlineError(from stderr: String) -> String {
    let lowered = stderr.lowercased()
    if lowered.contains("not logged in") || lowered.contains("authentication") || lowered.contains("please run /login") {
        return "Not signed in — run `claude` in a terminal once and log in, then try again."
    }
    let lastLine = stderr.split(separator: "\n").last.map(String.init) ?? stderr
    return String(lastLine.prefix(300))
}
