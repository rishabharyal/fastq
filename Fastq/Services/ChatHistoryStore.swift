import Foundation
import AppKit
import Combine

// MARK: - Persisted models

struct ChatSessionSummary: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var provider: ChatProvider
    var model: String
    var preview: String
    var messageCount: Int
}

struct ChatSessionDocument: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var provider: ChatProvider
    var model: String
    var messages: [PersistedChatMessage]
}

struct PersistedChatMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: String
    var text: String
    var attachments: [PersistedAttachment]
    var isError: Bool

    init(from message: ChatMessage) {
        id = message.id
        role = message.role == .user ? "user" : "assistant"
        text = message.text
        attachments = message.attachments.map(PersistedAttachment.init(from:))
        isError = message.isError
    }

    func toChatMessage() -> ChatMessage {
        ChatMessage(
            id: id,
            role: role == "user" ? .user : .assistant,
            text: text,
            attachments: attachments.map { $0.toPromptAttachment() },
            isError: isError
        )
    }
}

struct PersistedAttachment: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Absolute path under Application Support (durable).
    var path: String
    var isImage: Bool

    init(from attachment: PromptAttachment) {
        id = attachment.id
        name = attachment.name
        path = attachment.path
        isImage = attachment.isImage
    }

    func toPromptAttachment() -> PromptAttachment {
        PromptAttachment(id: id, name: name, path: path, isImage: isImage)
    }
}

private struct ChatIndexFile: Codable {
    var activeSessionID: UUID?
    var sessions: [ChatSessionSummary]
}

// MARK: - Store

/// File-backed chat history under Application Support so transcripts and
/// attachment bytes survive relaunches.
@MainActor
final class ChatHistoryStore: ObservableObject {
    @Published private(set) var sessions: [ChatSessionSummary] = []
    @Published private(set) var activeSessionID: UUID?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var rootURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Fastq/chats", isDirectory: true)
    }

    private var indexURL: URL { rootURL.appendingPathComponent("index.json") }
    private var sessionsURL: URL { rootURL.appendingPathComponent("sessions", isDirectory: true) }
    private var attachmentsURL: URL { rootURL.appendingPathComponent("attachments", isDirectory: true) }

    init() {
        ensureDirectories()
        reloadIndex()
    }

    // MARK: - Public API

    func reloadIndex() {
        ensureDirectories()
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? decoder.decode(ChatIndexFile.self, from: data) else {
            sessions = []
            activeSessionID = nil
            return
        }
        sessions = index.sessions.sorted { $0.updatedAt > $1.updatedAt }
        activeSessionID = index.activeSessionID
    }

    func setActiveSessionID(_ id: UUID?) {
        activeSessionID = id
        writeIndex()
    }

    func loadSession(_ id: UUID) -> ChatSessionDocument? {
        let url = sessionURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let document = try? decoder.decode(ChatSessionDocument.self, from: data) else {
            return nil
        }
        return document
    }

    /// Persist a full session document and refresh the summary index.
    @discardableResult
    func saveSession(
        id: UUID,
        messages: [ChatMessage],
        provider: ChatProvider,
        model: String,
        createdAt: Date,
        updatedAt: Date,
        makeActive: Bool = true
    ) -> ChatSessionSummary? {
        guard !messages.isEmpty else { return nil }
        ensureDirectories()

        let durableMessages = messages.map { message -> ChatMessage in
            var copy = message
            copy.attachments = copyAttachments(message.attachments, sessionID: id)
            return copy
        }

        let title = Self.makeTitle(from: durableMessages)
        let preview = Self.makePreview(from: durableMessages)
        let document = ChatSessionDocument(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            provider: provider,
            model: model,
            messages: durableMessages.map(PersistedChatMessage.init(from:))
        )

        do {
            try writeAtomically(document, to: sessionURL(for: id))
        } catch {
            NSLog("Fastq chat: failed to save session \(id): \(error.localizedDescription)")
            return nil
        }

        let summary = ChatSessionSummary(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            provider: provider,
            model: model,
            preview: preview,
            messageCount: durableMessages.count
        )
        upsertSummary(summary)
        if makeActive {
            activeSessionID = id
        }
        writeIndex()
        return summary
    }

    func deleteSession(_ id: UUID) {
        try? fileManager.removeItem(at: sessionURL(for: id))
        try? fileManager.removeItem(at: attachmentsURL.appendingPathComponent(id.uuidString, isDirectory: true))
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = nil
        }
        writeIndex()
    }

    /// Copy attachment files into Application Support so temp pastes survive.
    func copyAttachments(_ attachments: [PromptAttachment], sessionID: UUID) -> [PromptAttachment] {
        guard !attachments.isEmpty else { return [] }
        let folder = attachmentsURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        return attachments.map { attachment in
            let source = URL(fileURLWithPath: attachment.path)
            let destName = "\(attachment.id.uuidString)-\(sanitizeFileName(attachment.name))"
            let dest = folder.appendingPathComponent(destName)

            if attachment.path == dest.path, fileManager.fileExists(atPath: dest.path) {
                return attachment
            }
            if fileManager.fileExists(atPath: dest.path) {
                return PromptAttachment(id: attachment.id, name: attachment.name, path: dest.path, isImage: attachment.isImage)
            }
            do {
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: dest)
                    return PromptAttachment(id: attachment.id, name: attachment.name, path: dest.path, isImage: attachment.isImage)
                }
            } catch {
                NSLog("Fastq chat: attachment copy failed: \(error.localizedDescription)")
            }
            return attachment
        }
    }

    // MARK: - Private

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
    }

    private func sessionURL(for id: UUID) -> URL {
        sessionsURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func upsertSummary(_ summary: ChatSessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == summary.id }) {
            sessions[index] = summary
        } else {
            sessions.insert(summary, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func writeIndex() {
        ensureDirectories()
        let index = ChatIndexFile(activeSessionID: activeSessionID, sessions: sessions)
        do {
            try writeAtomically(index, to: indexURL)
        } catch {
            NSLog("Fastq chat: failed to write index: \(error.localizedDescription)")
        }
    }

    private func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: url)
        }
    }

    private func sanitizeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "file" : cleaned
    }

    static func makeTitle(from messages: [ChatMessage]) -> String {
        let firstUser = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstUser.isEmpty { return "New chat" }
        let collapsed = firstUser.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= 48 { return collapsed }
        return String(collapsed.prefix(45)) + "…"
    }

    static func makePreview(from messages: [ChatMessage]) -> String {
        guard let last = messages.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return ""
        }
        let collapsed = last.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(77)) + "…"
    }
}
