import SwiftUI

/// Full conversation view for one headless agent session — replaces the
/// embedded terminal. Chat-style transcript + composer at the bottom.
struct AgentChatView: View {
    @ObservedObject var session: AgentChatSession
    @ObservedObject var store: AgentChatStore
    var onClose: (() -> Void)?

    @State private var followUp = ""
    @State private var followUpAttachments: [PromptAttachment] = []

    /// Shared by the attach button, drag-and-drop and paste — all three land here.
    private func addAttachments(_ urls: [URL]) {
        for url in urls where !followUpAttachments.contains(where: { $0.path == url.path }) {
            followUpAttachments.append(PromptAttachment(url: url))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            transcript
            Divider().opacity(0.4)
            AgentComposerBar(
                text: $followUp,
                attachments: $followUpAttachments,
                placeholder: composerPlaceholder,
                isBusy: session.isBusy,
                queuedCount: session.queuedPrompts.count,
                permissionPreset: Binding(
                    get: { store.permissionPreset },
                    set: { store.permissionPreset = $0 }
                ),
                model: .constant(session.model),
                showsModelPicker: false,
                onAttach: {
                    FolderPicker.chooseFiles { urls in
                        addAttachments(urls)
                    }
                },
                onStop: { store.stop(sessionID: session.id) },
                contextLabel: URL(fileURLWithPath: session.projectPath).lastPathComponent,
                onAttachURLs: { urls in addAttachments(urls) },
                onSubmit: sendFollowUp
            )
            .padding(FQTheme.space3)
        }
        .background(FQTheme.background)
        .onAppear {
            // Route panel-wide ⌘V / file drops into this composer while open.
            LauncherKeyRouter.shared.chatComposerAttach = { [_attachments = $followUpAttachments] urls in
                var current = _attachments.wrappedValue
                for url in urls where !current.contains(where: { $0.path == url.path }) {
                    current.append(PromptAttachment(url: url))
                }
                _attachments.wrappedValue = current
            }
        }
        .onDisappear {
            LauncherKeyRouter.shared.chatComposerAttach = nil
        }
    }

    private var header: some View {
        HStack(spacing: FQTheme.space2) {
            if let onClose {
                FQIconButton(systemImage: "chevron.left", size: 24, iconSize: 11, help: "Back") {
                    onClose()
                }
            }
            FQAvatar(kind: .agent(session.tool), size: 22)
            Text(session.title)
                .font(FQTheme.fontBodyMedium)
                .lineLimit(1)
            Text(session.projectName)
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textSecondary)
            Spacer()
            if let cost = session.costUSD {
                FQBadge(text: String(format: "$%.2f", cost), tone: .neutral)
            }
            phaseBadge
        }
        .padding(.horizontal, FQTheme.space3)
        .padding(.vertical, FQTheme.space2)
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch session.phase {
        case .running:
            FQBadge(text: "Running", tone: .accent, systemImage: "circle.fill")
        case .waitingForUser:
            FQBadge(text: "Needs you", tone: .warning, systemImage: "hand.raised.fill")
        case .done:
            FQBadge(text: "Done", tone: .success, systemImage: "checkmark")
        case .failed:
            FQBadge(text: "Failed", tone: .danger, systemImage: "xmark")
        case .idle:
            EmptyView()
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FQTheme.space4) {
                    FQLabeledDivider(text: dayLabel)
                        .padding(.top, FQTheme.space3)

                    ForEach(session.items) { item in
                        itemView(item)
                            .id(item.id)
                    }

                    if let status = session.statusLine, session.phase == .running {
                        AgentStatusRow(text: status)
                    }

                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, FQTheme.space4)
                .padding(.bottom, FQTheme.space3)
            }
            .onChange(of: session.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.statusLine) { _, _ in
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: AgentChatItem) -> some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments, date: item.date)

        case .assistantText(let text):
            AssistantRow(tool: session.tool) {
                MarkdownText(text: text)
            }

        case .toolCalls(let calls):
            AssistantRow(tool: session.tool, showAvatar: false) {
                ToolCallGroup(calls: calls)
            }

        case .question(let record):
            AssistantRow(tool: session.tool) {
                QuestionCard(
                    record: record,
                    isPending: session.pending?.itemID == item.id,
                    onAnswer: { answers in
                        store.answerQuestion(session: session, answers: answers)
                    }
                )
            }

        case .permission(let record):
            AssistantRow(tool: session.tool, showAvatar: false) {
                PermissionCard(
                    record: record,
                    isPending: session.pending?.itemID == item.id,
                    onDecision: { allow in
                        store.resolvePermission(session: session, allow: allow)
                    }
                )
            }

        case .result(let record):
            RunResultRow(record: record)

        case .error(let message):
            AssistantRow(tool: session.tool, showAvatar: false) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(FQTheme.danger)
                    Text(message)
                        .font(FQTheme.fontSmall)
                        .foregroundStyle(FQTheme.danger)
                        .textSelection(.enabled)
                }
                .padding(FQTheme.space2)
                .background(FQTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
            }
        }
    }

    private var dayLabel: String {
        guard let first = session.items.first?.date else { return "Today" }
        if Calendar.current.isDateInToday(first) { return "Today" }
        if Calendar.current.isDateInYesterday(first) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: first)
    }

    private var composerPlaceholder: String {
        guard session.isBusy else { return "Reply…" }
        return session.tool == .claudeCode
            ? "Reply — runs right after the current step…"
            : "Reply — queued until this run finishes…"
    }

    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let files = followUpAttachments.map(\.path)
        followUp = ""
        followUpAttachments = []
        store.sendFollowUp(sessionID: session.id, prompt: text, attachments: files)
    }
}

// MARK: - Rows

/// Right-aligned gray user bubble with attachment chips + timestamp.
struct UserBubble: View {
    let text: String
    let attachments: [String]
    let date: Date

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if !attachments.isEmpty {
                HStack(spacing: 5) {
                    ForEach(attachments, id: \.self) { name in
                        FQChip(title: (name as NSString).lastPathComponent)
                    }
                }
            }
            HStack(alignment: .top, spacing: 0) {
                (Text("@Agent  ").font(FQTheme.fontSmall.weight(.semibold)).foregroundColor(FQTheme.accent)
                    + Text(text).font(FQTheme.fontBody))
                    .foregroundStyle(FQTheme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(2.5)
            }
            .padding(.horizontal, FQTheme.space4)
            .padding(.vertical, 10)
            .background(FQTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: FQTheme.radiusLarge, style: .continuous))
            .frame(maxWidth: 460, alignment: .trailing)

            Text(Self.time.string(from: date))
                .font(FQTheme.fontCaption)
                .foregroundStyle(FQTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

/// Left column layout for assistant content: avatar gutter + content.
struct AssistantRow<Content: View>: View {
    let tool: AgentToolKind
    var showAvatar = true
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: FQTheme.space3) {
            if showAvatar {
                FQAvatar(kind: .agent(tool), size: 28)
            } else {
                Color.clear.frame(width: 28, height: 1)
            }
            content
                .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

/// Shimmering "Thinking…" / "Running bash…" status row.
struct AgentStatusRow: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(FQTheme.accent)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text(text)
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textSecondary)
        }
        .padding(.leading, 40)
        .onAppear { pulse = true }
    }
}

/// Subtle end-of-run footer: "Done · $0.04 · 32s".
struct RunResultRow: View {
    let record: RunResultRecord

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: record.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(record.ok ? FQTheme.success : FQTheme.danger)
            Text(label)
                .font(FQTheme.fontCaption)
                .foregroundStyle(FQTheme.textSecondary)
            if !record.ok, !record.text.isEmpty {
                Text(record.text)
                    .font(FQTheme.fontCaption)
                    .foregroundStyle(FQTheme.danger)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 40)
    }

    private var label: String {
        var parts = [record.ok ? "Done" : "Failed"]
        if let cost = record.costUSD {
            parts.append(String(format: "$%.4f", cost))
        }
        if let ms = record.durationMs {
            parts.append(ms < 60_000 ? String(format: "%.0fs", Double(ms) / 1000) : String(format: "%.1fm", Double(ms) / 60_000))
        }
        return parts.joined(separator: " · ")
    }
}
