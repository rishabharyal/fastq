import SwiftUI

/// Chat-mode content area: scrolling message thread with streaming replies.
struct ChatModeView: View {
    @ObservedObject var chat: ChatService
    var providerName: String
    var modelName: String

    var body: some View {
        Group {
            if chat.messages.isEmpty {
                emptyState
            } else {
                thread
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Chat with \(modelName)")
                .font(.headline)
            Text("Ask anything — paste or attach images and PDFs with ⌘V or the paperclip.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Text("⌘2 switches back to agent mode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var thread: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(providerName) · \(modelName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if chat.isStreaming {
                    Button("Stop") { chat.stop() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Button("Clear") { chat.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            ChatBubble(message: message, isStreaming: isStreamingMessage(message))
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
                .onChange(of: chat.messages) { _, messages in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func isStreamingMessage(_ message: ChatMessage) -> Bool {
        chat.isStreaming && message.id == chat.messages.last?.id && message.role == .assistant
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 6) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: attachment.isImage ? "photo" : "doc")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(attachment.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if message.text.isEmpty && isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(renderedText)
                        .font(.system(size: 13))
                        .foregroundStyle(message.isError ? Color.red.opacity(0.9) : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.role == .user
                          ? Color.accentColor.opacity(0.18)
                          : Color.white.opacity(0.06))
            )

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    /// Markdown when it parses, plain text otherwise; streaming partials get
    /// a trailing cursor.
    private var renderedText: AttributedString {
        let text = isStreaming ? message.text + " ▍" : message.text
        if let markdown = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return markdown
        }
        return AttributedString(text)
    }
}
