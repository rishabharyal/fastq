import Foundation
import SwiftUI
import Combine

// MARK: - Provider / model catalog

enum ChatProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    /// (model id, display name) — id is what goes on the wire.
    var models: [(id: String, name: String)] {
        switch self {
        case .anthropic:
            return [
                ("claude-opus-4-8", "Claude Opus 4.8"),
                ("claude-sonnet-5", "Claude Sonnet 5"),
                ("claude-haiku-4-5", "Claude Haiku 4.5"),
            ]
        case .openai:
            return [
                ("gpt-5", "GPT-5"),
                ("gpt-4o", "GPT-4o"),
                ("o3", "o3"),
            ]
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openai: return "gpt-5"
        }
    }

    func displayName(forModel id: String) -> String {
        models.first(where: { $0.id == id })?.name ?? id
    }
}

// MARK: - Message model

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    /// Attachments sent with this (user) message — kept for display and
    /// so multi-turn requests can re-encode them from disk.
    var attachments: [PromptAttachment] = []
    var isError = false

    init(id: UUID = UUID(), role: Role, text: String, attachments: [PromptAttachment] = [], isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.isError = isError
    }
}

// MARK: - Service

/// General-purpose chat backed by the Anthropic / OpenAI APIs, with streaming
/// responses and image / PDF / text attachments. Sessions persist via
/// `ChatHistoryStore` and auto-reset after one hour of inactivity.
@MainActor
final class ChatService: ObservableObject {
    static let inactivityInterval: TimeInterval = 60 * 60

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var sessionID = UUID()
    @Published private(set) var sessionCreatedAt = Date()
    @Published private(set) var sessionUpdatedAt = Date()

    private var streamTask: Task<Void, Never>?
    private weak var historyStore: ChatHistoryStore?
    private var currentProvider: ChatProvider = .anthropic
    private var currentModel: String = ChatProvider.anthropic.defaultModel
    private var inactivityTimer: Timer?
    private var didBootstrap = false
    private var terminateObserver: NSObjectProtocol?

    func bind(historyStore: ChatHistoryStore) {
        self.historyStore = historyStore
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.persistCurrentSession()
                }
            }
        }
        guard !didBootstrap else {
            resetIfInactive()
            return
        }
        didBootstrap = true
        restoreActiveSessionOrFresh()
        scheduleInactivityTimer()
    }

    /// Persist the open thread without clearing it (e.g. app quit).
    func persistIfNeeded() {
        persistCurrentSession()
    }

    /// Restore the last active chat unless it went idle for an hour.
    func restoreActiveSessionOrFresh() {
        guard let store = historyStore,
              let activeID = store.activeSessionID,
              let document = store.loadSession(activeID) else {
            startNewChat(persistCurrent: false)
            return
        }
        if Date().timeIntervalSince(document.updatedAt) >= Self.inactivityInterval {
            store.setActiveSessionID(nil)
            startNewChat(persistCurrent: false)
            return
        }
        apply(document: document)
        scheduleInactivityTimer()
    }

    /// If the current thread has been idle ≥ 1 hour, archive it and start fresh.
    @discardableResult
    func resetIfInactive(now: Date = Date()) -> Bool {
        guard !messages.isEmpty else { return false }
        guard now.timeIntervalSince(sessionUpdatedAt) >= Self.inactivityInterval else { return false }
        persistCurrentSession()
        startNewChat(persistCurrent: false)
        return true
    }

    /// ⌘N / Clear — keep the previous thread in history and open a blank chat.
    func startNewChat(persistCurrent: Bool = true) {
        if persistCurrent {
            persistCurrentSession()
        }
        stop()
        messages = []
        isStreaming = false
        sessionID = UUID()
        sessionCreatedAt = Date()
        sessionUpdatedAt = Date()
        historyStore?.setActiveSessionID(nil)
        scheduleInactivityTimer()
    }

    func openSession(_ id: UUID) {
        guard let document = historyStore?.loadSession(id) else { return }
        if !messages.isEmpty, messages.contains(where: { !$0.text.isEmpty }) {
            persistCurrentSession()
        }
        stop()
        apply(document: document)
        historyStore?.setActiveSessionID(id)
        scheduleInactivityTimer()
    }

    func deleteSession(_ id: UUID) {
        let wasCurrent = sessionID == id
        historyStore?.deleteSession(id)
        if wasCurrent {
            startNewChat(persistCurrent: false)
        }
    }

    func send(text: String, attachments: [PromptAttachment], provider: ChatProvider, model: String, apiKey: String) {
        guard !isStreaming else { return }
        resetIfInactive()

        currentProvider = provider
        currentModel = model
        let durableAttachments = historyStore?.copyAttachments(attachments, sessionID: sessionID) ?? attachments
        messages.append(ChatMessage(role: .user, text: text, attachments: durableAttachments))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
        touchActivity()
        persistCurrentSession()
        isStreaming = true

        let history = messages
        streamTask = Task { [weak self] in
            do {
                let request = try Self.buildRequest(history: history, provider: provider, model: model, apiKey: apiKey)
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ChatError.transport("No HTTP response.")
                }
                guard http.statusCode == 200 else {
                    var body = ""
                    for try await line in bytes.lines {
                        body += line
                        if body.count > 4_000 { break }
                    }
                    throw ChatError.api(Self.apiErrorMessage(status: http.statusCode, body: body))
                }
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.hasPrefix("data:") else { continue }
                    let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let delta = Self.textDelta(from: json, provider: provider), !delta.isEmpty {
                        await MainActor.run {
                            self?.appendDelta(delta, to: assistantID)
                        }
                    }
                    if let apiError = Self.streamError(from: json, provider: provider) {
                        throw ChatError.api(apiError)
                    }
                }
                await MainActor.run { self?.finishStream(assistantID: assistantID, error: nil) }
            } catch is CancellationError {
                await MainActor.run { self?.finishStream(assistantID: assistantID, error: nil) }
            } catch {
                let message = (error as? ChatError)?.message ?? error.localizedDescription
                await MainActor.run { self?.finishStream(assistantID: assistantID, error: message) }
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Legacy alias — archives then starts a new chat.
    func clear() {
        startNewChat(persistCurrent: true)
    }

    private func apply(document: ChatSessionDocument) {
        sessionID = document.id
        sessionCreatedAt = document.createdAt
        sessionUpdatedAt = document.updatedAt
        currentProvider = document.provider
        currentModel = document.model
        messages = document.messages.map { $0.toChatMessage() }
        isStreaming = false
    }

    private func touchActivity() {
        sessionUpdatedAt = Date()
        scheduleInactivityTimer()
    }

    private func persistCurrentSession() {
        guard !messages.isEmpty else { return }
        historyStore?.saveSession(
            id: sessionID,
            messages: messages,
            provider: currentProvider,
            model: currentModel,
            createdAt: sessionCreatedAt,
            updatedAt: sessionUpdatedAt,
            makeActive: true
        )
    }

    private func scheduleInactivityTimer() {
        inactivityTimer?.invalidate()
        let remaining = Self.inactivityInterval - Date().timeIntervalSince(sessionUpdatedAt)
        let delay = max(1, remaining)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resetIfInactive()
            }
        }
    }

    private func appendDelta(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
    }

    private func finishStream(assistantID: UUID, error: String?) {
        isStreaming = false
        streamTask = nil
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if let error {
            if messages[index].text.isEmpty {
                messages[index].text = error
                messages[index].isError = true
            } else {
                messages[index].text += "\n\n⚠️ \(error)"
            }
        } else if messages[index].text.isEmpty {
            messages[index].text = "(no response)"
        }
        touchActivity()
        persistCurrentSession()
    }

    // MARK: - Request building

    private enum ChatError: Error {
        case transport(String)
        case api(String)

        var message: String {
            switch self {
            case .transport(let m), .api(let m): return m
            }
        }
    }

    private static func buildRequest(history: [ChatMessage], provider: ChatProvider, model: String, apiKey: String) throws -> URLRequest {
        switch provider {
        case .anthropic: return try anthropicRequest(history: history, model: model, apiKey: apiKey)
        case .openai: return try openAIRequest(history: history, model: model, apiKey: apiKey)
        }
    }

    private static func anthropicRequest(history: [ChatMessage], model: String, apiKey: String) throws -> URLRequest {
        var apiMessages: [[String: Any]] = []
        for message in history where !(message.role == .assistant && message.text.isEmpty) {
            switch message.role {
            case .assistant:
                apiMessages.append(["role": "assistant", "content": message.text])
            case .user:
                var blocks: [[String: Any]] = []
                for attachment in message.attachments {
                    if let block = anthropicBlock(for: attachment) {
                        blocks.append(block)
                    }
                }
                blocks.append(["type": "text", "text": message.text])
                apiMessages.append(["role": "user", "content": blocks])
            }
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 64_000,
            "stream": true,
            "system": Self.mathAwareSystemPrompt,
            "messages": apiMessages,
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300
        return request
    }

    /// Anthropic content block for one attachment; images and PDFs go as
    /// native blocks, small text files inline, anything else is skipped.
    private static func anthropicBlock(for attachment: PromptAttachment) -> [String: Any]? {
        let url = URL(fileURLWithPath: attachment.path)
        guard let data = try? Data(contentsOf: url), data.count <= 30_000_000 else { return nil }
        if attachment.isImage, let mediaType = imageMediaType(for: url) {
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()],
            ]
        }
        if url.pathExtension.lowercased() == "pdf" {
            return [
                "type": "document",
                "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()],
            ]
        }
        if let text = inlineText(from: data, name: attachment.name) {
            return ["type": "text", "text": text]
        }
        return nil
    }

    private static func openAIRequest(history: [ChatMessage], model: String, apiKey: String) throws -> URLRequest {
        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": Self.mathAwareSystemPrompt]
        ]
        for message in history where !(message.role == .assistant && message.text.isEmpty) {
            switch message.role {
            case .assistant:
                apiMessages.append(["role": "assistant", "content": message.text])
            case .user:
                var parts: [[String: Any]] = []
                for attachment in message.attachments {
                    if let part = openAIPart(for: attachment) {
                        parts.append(part)
                    }
                }
                parts.append(["type": "text", "text": message.text])
                apiMessages.append(["role": "user", "content": parts])
            }
        }

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": apiMessages,
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300
        return request
    }

    private static func openAIPart(for attachment: PromptAttachment) -> [String: Any]? {
        let url = URL(fileURLWithPath: attachment.path)
        guard let data = try? Data(contentsOf: url), data.count <= 30_000_000 else { return nil }
        if attachment.isImage, let mediaType = imageMediaType(for: url) {
            return [
                "type": "image_url",
                "image_url": ["url": "data:\(mediaType);base64,\(data.base64EncodedString())"],
            ]
        }
        if url.pathExtension.lowercased() == "pdf" {
            return [
                "type": "file",
                "file": [
                    "filename": attachment.name,
                    "file_data": "data:application/pdf;base64,\(data.base64EncodedString())",
                ],
            ]
        }
        if let text = inlineText(from: data, name: attachment.name) {
            return ["type": "text", "text": text]
        }
        return nil
    }

    private static let mathAwareSystemPrompt = """
    You are a helpful assistant in the Fastq launcher.
    Structure replies for readability:
    - Use Markdown with blank lines between paragraphs and sections
    - Use ## / ### headings for distinct topics
    - Use bullet lists for pros/cons and steps
    For any mathematics, physics, or symbolic content, write LaTeX that KaTeX can render:
    - Display equations on their own lines wrapped in $$ ... $$ (preferred) or \\[ ... \\]
    - Inline math in $ ... $ or \\( ... \\)
    - Prefer clear step-by-step solutions for math questions
    - Use fenced code blocks with a language tag for code
    Do not wrap LaTeX in markdown code fences unless the user asked for the raw TeX source.
    """

    private static func imageMediaType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil // HEIC/TIFF aren't accepted by either API
        }
    }

    /// Inline a text file (source code, markdown, …) into the prompt, capped.
    private static func inlineText(from data: Data, name: String) -> String? {
        guard data.count <= 400_000, let content = String(data: data, encoding: .utf8) else { return nil }
        return "Attached file `\(name)`:\n```\n\(content)\n```"
    }

    // MARK: - Stream parsing

    private static func textDelta(from json: [String: Any], provider: ChatProvider) -> String? {
        switch provider {
        case .anthropic:
            guard json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        case .openai:
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { return nil }
            return delta["content"] as? String
        }
    }

    private static func streamError(from json: [String: Any], provider: ChatProvider) -> String? {
        guard let error = json["error"] as? [String: Any] else {
            if provider == .anthropic, json["type"] as? String == "error",
               let inner = (json["error"] as? [String: Any])?["message"] as? String {
                return inner
            }
            return nil
        }
        return error["message"] as? String ?? "The provider returned an error."
    }

    private static func apiErrorMessage(status: Int, body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        switch status {
        case 401: return "Invalid API key. Check Settings → Chat."
        case 429: return "Rate limited — try again in a moment."
        default: return "Request failed (HTTP \(status))."
        }
    }
}
