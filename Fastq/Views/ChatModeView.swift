import SwiftUI
import AppKit

/// Chat-mode content area: scrolling message thread with streaming replies,
/// rich markdown / code / KaTeX math, attachment previews, and chat history.
struct ChatModeView: View {
    @ObservedObject var chat: ChatService
    @ObservedObject var history: ChatHistoryStore
    var providerName: String
    var modelName: String
    var onNewChat: () -> Void

    @State private var showHistory = false
    /// When false, streaming updates won't yank the scroll position — user is reading above.
    @State private var pinToBottom = true

    var body: some View {
        Group {
            if chat.messages.isEmpty {
                emptyState
            } else {
                thread
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if showHistory {
                historyPopover
                    .padding(.top, 40)
                    .padding(.trailing, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showHistory)
        .onChange(of: chat.messages.count) { oldCount, newCount in
            // New user turn → resume follow-tail.
            if newCount > oldCount {
                pinToBottom = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            chatToolbar
            Spacer(minLength: 0)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Chat with \(modelName)")
                .font(.headline)
            Text("Ask anything — attach images, PDFs, or files with ⌘V or the paperclip. Math and code render richly in replies.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Try: “solve ∫₀¹ x² dx” or paste a screenshot")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("History keeps past threads · idle chats reset after 1 hour · New starts a blank chat")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var thread: some View {
        VStack(spacing: 0) {
            chatToolbar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.messages) { message in
                            ChatBubble(message: message, isStreaming: isStreamingMessage(message))
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .background(
                        ChatScrollFollowMonitor(pinToBottom: $pinToBottom)
                            .frame(width: 0, height: 0)
                    )
                }
                .onChange(of: chat.messages) { _, messages in
                    scrollToBottomIfPinned(proxy: proxy, messages: messages)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    scrollToBottomIfPinned(proxy: proxy, messages: chat.messages)
                }
                .onChange(of: pinToBottom) { _, pinned in
                    if pinned {
                        scrollToBottomIfPinned(proxy: proxy, messages: chat.messages, animated: true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !pinToBottom, !chat.messages.isEmpty {
                        Button {
                            pinToBottom = true
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 28, height: 28)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                        .help("Jump to latest")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: pinToBottom)
            }
        }
    }

    private func scrollToBottomIfPinned(
        proxy: ScrollViewProxy,
        messages: [ChatMessage],
        animated: Bool = false
    ) {
        guard pinToBottom, let last = messages.last else { return }
        ChatScrollFollowMonitor.noteProgrammaticScroll()
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            // Avoid fighting the user with a spring on every token.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var chatToolbar: some View {
        HStack(spacing: 10) {
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
            Button {
                showHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(showHistory ? Color.accentColor : .secondary)
            .help("Open previous chats")

            Button("New") { onNewChat() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .help("New chat")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Previous chats")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    showHistory = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.35)

            if history.sessions.isEmpty {
                Text("No saved chats yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(history.sessions) { session in
                            historyRow(session)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func historyRow(_ session: ChatSessionSummary) -> some View {
        let isCurrent = session.id == chat.sessionID && !chat.messages.isEmpty
        return Button {
            chat.openSession(session.id)
            showHistory = false
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(session.preview.isEmpty ? "\(session.messageCount) messages" : session.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(Self.relativeDate(session.updatedAt))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Text("Open")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") {
                chat.openSession(session.id)
                showHistory = false
            }
            Button("Delete", role: .destructive) {
                chat.deleteSession(session.id)
            }
        }
    }

    private func isStreamingMessage(_ message: ChatMessage) -> Bool {
        chat.isStreaming && message.id == chat.messages.last?.id && message.role == .assistant
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 8) {
                if !message.attachments.isEmpty {
                    ChatAttachmentStrip(attachments: message.attachments)
                }

                if message.text.isEmpty && isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if !message.text.isEmpty || isStreaming {
                    ChatRichContentView(
                        text: message.text,
                        isStreaming: isStreaming,
                        isError: message.isError
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: message.role == .assistant ? .infinity : 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.role == .user
                          ? Color.accentColor.opacity(0.18)
                          : Color.white.opacity(0.06))
            )

            if message.role == .assistant { Spacer(minLength: 24) }
        }
    }
}

private struct ChatAttachmentStrip: View {
    let attachments: [PromptAttachment]

    var body: some View {
        FlowishHStack(spacing: 6) {
            ForEach(attachments) { attachment in
                ChatAttachmentChip(attachment: attachment)
            }
        }
    }
}

private struct ChatAttachmentChip: View {
    let attachment: PromptAttachment

    var body: some View {
        HStack(spacing: 6) {
            if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: attachment.isImage ? "photo" : docSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(attachment.isImage ? "Image" : (attachment.path as NSString).pathExtension.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .padding(.leading, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .help(attachment.path)
        .onTapGesture {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)])
        }
    }

    private var docSymbol: String {
        switch (attachment.path as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "md", "txt": return "doc.plaintext"
        case "swift", "py", "js", "ts", "json": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// Simple wrapping horizontal stack for attachment chips.
private struct FlowishHStack<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: spacing) { content }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: spacing) { content }
            }
        }
    }
}

/// Watches the enclosing `NSScrollView` so streaming auto-scroll only runs
/// while the user is near the bottom. Manual scroll-up clears the pin.
private struct ChatScrollFollowMonitor: NSViewRepresentable {
    @Binding var pinToBottom: Bool

    private static let bottomSlack: CGFloat = 72
    private static var programmaticUntil: CFAbsoluteTime = 0

    static func noteProgrammaticScroll() {
        programmaticUntil = CFAbsoluteTimeGetCurrent() + 0.2
    }

    private static var isProgrammaticScroll: Bool {
        CFAbsoluteTimeGetCurrent() < programmaticUntil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(pinToBottom: $pinToBottom)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.pinToBottom = $pinToBottom
        DispatchQueue.main.async {
            context.coordinator.attach(from: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var pinToBottom: Binding<Bool>
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var boundsObserver: NSObjectProtocol?

        init(pinToBottom: Binding<Bool>) {
            self.pinToBottom = pinToBottom
        }

        func attach(from view: NSView) {
            guard let scroll = view.enclosingScrollView else { return }
            if scrollView === scroll { return }
            detach()
            scrollView = scroll

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scroll,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleUserScrollActivity()
                },
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: scroll,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleUserScrollActivity()
                },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scroll,
                    queue: .main
                ) { [weak self] _ in
                    self?.refreshPinFromPosition()
                },
            ]

            boundsObserver = center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.refreshPinFromPosition()
            }
            scroll.contentView.postsBoundsChangedNotifications = true
        }

        func detach() {
            let center = NotificationCenter.default
            for observer in observers {
                center.removeObserver(observer)
            }
            observers = []
            if let boundsObserver {
                center.removeObserver(boundsObserver)
            }
            boundsObserver = nil
            scrollView = nil
        }

        private func handleUserScrollActivity() {
            guard !ChatScrollFollowMonitor.isProgrammaticScroll else { return }
            refreshPinFromPosition(forceUnpinIfAway: true)
        }

        private func refreshPinFromPosition(forceUnpinIfAway: Bool = false) {
            guard let scroll = scrollView else { return }
            if ChatScrollFollowMonitor.isProgrammaticScroll { return }

            let doc = scroll.documentVisibleRect
            let contentHeight = scroll.documentView?.bounds.height ?? doc.height
            let distanceFromBottom = contentHeight - doc.maxY
            let nearBottom = distanceFromBottom <= ChatScrollFollowMonitor.bottomSlack

            if nearBottom {
                if !pinToBottom.wrappedValue {
                    pinToBottom.wrappedValue = true
                }
            } else if forceUnpinIfAway || pinToBottom.wrappedValue {
                // User moved away from the bottom — stop yanking them down.
                if pinToBottom.wrappedValue {
                    pinToBottom.wrappedValue = false
                }
            }
        }
    }
}

