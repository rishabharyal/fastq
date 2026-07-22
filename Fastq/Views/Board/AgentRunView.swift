import SwiftUI
import AppKit

/// One agent run, opened as a tab in the board window.
///
/// Left: the agent's live progress (the headless chat transcript).
/// Right: an inspector rail — task details, an inline terminal for quick
/// commands, the project's files, and the working-tree diff.
struct AgentRunView: View {
    let sessionID: UUID
    @ObservedObject var sessions: SessionStore
    @ObservedObject var boardStore: BoardStore
    let projectPath: String?
    var onClose: () -> Void
    var onOpenTaskDetail: (FastplayTask) -> Void = { _ in }

    @ObservedObject private var chatStore = AgentChatStore.shared
    @StateObject private var files = ProjectFilesModel()
    @StateObject private var diff = GitDiffModel()

    /// Inspector width, persisted so the split doesn't jump between runs.
    @AppStorage("fastq.board.inspectorWidth") private var inspectorWidth: Double = 380
    @AppStorage("fastq.board.inspectorPane") private var storedPane: String = InspectorPane.task.rawValue

    private var pane: InspectorPane {
        InspectorPane(rawValue: storedPane) ?? .task
    }

    var body: some View {
        HStack(spacing: 0) {
            progressPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ResizeHandle(
                width: $inspectorWidth,
                range: 300...760,
                isTrailingPane: true,
                accessibilityName: "inspector"
            )

            inspector
                .frame(width: CGFloat(inspectorWidth))
                .frame(maxHeight: .infinity)
        }
        .background(FQTheme.background)
        .onAppear { syncRoots() }
        .onChange(of: projectPath) { _, _ in syncRoots() }
    }

    private func syncRoots() {
        files.setRoot(projectPath)
        diff.setRoot(projectPath)
    }

    // MARK: - Left: agent progress

    @ViewBuilder
    private var progressPane: some View {
        if let chat = chatStore.session(id: sessionID) {
            AgentChatView(session: chat, store: chatStore, onClose: onClose)
        } else if let session = sessions.session(id: sessionID) {
            missingTranscript(for: session)
        } else {
            ContentUnavailableView(
                "Run ended",
                systemImage: "sparkles",
                description: Text("This agent session is no longer available.")
            )
        }
    }

    private func missingTranscript(for session: AgentSession) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)
            Text(session.promptPreview.isEmpty ? session.tool.displayName : session.promptPreview)
                .font(FQTheme.fontBodyMedium)
                .foregroundStyle(FQTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("No transcript for this session — it isn't a chat-mode agent.")
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right: inspector + mini rail

    private var inspector: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                inspectorHeader
                Divider()
                inspectorBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            rail
        }
        .background(FQTheme.surface)
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: pane.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FQTheme.textSecondary)
            Text(pane.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FQTheme.textPrimary)
            Spacer(minLength: 0)
            if let projectPath {
                Text(URL(fileURLWithPath: projectPath).lastPathComponent)
                    .font(FQTheme.fontCaption)
                    .foregroundStyle(FQTheme.textTertiary)
                    .lineLimit(1)
                    .help(projectPath)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// All panes stay mounted: the terminal owns a live PTY and unmounting it
    /// would kill the shell and lose scrollback.
    private var inspectorBody: some View {
        ZStack {
            taskPane
                .opacity(pane == .task ? 1 : 0)
                .allowsHitTesting(pane == .task)

            InlineTerminalPane(
                terminals: sessions.terminals,
                projectPath: projectPath,
                isActive: pane == .terminal
            )
            .opacity(pane == .terminal ? 1 : 0)
            .allowsHitTesting(pane == .terminal)

            ProjectFilesPane(model: files)
                .opacity(pane == .files ? 1 : 0)
                .allowsHitTesting(pane == .files)

            GitDiffPane(model: diff)
                .opacity(pane == .git ? 1 : 0)
                .allowsHitTesting(pane == .git)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(InspectorPane.allCases) { item in
                railButton(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(FQTheme.background)
    }

    private func railButton(_ item: InspectorPane) -> some View {
        let isSelected = pane == item
        return Button {
            storedPane = item.rawValue
        } label: {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? FQTheme.onControlPrimary : FQTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                        .fill(isSelected ? FQTheme.accent : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel("\(item.title)\(isSelected ? ", selected" : "")")
    }

    // MARK: - Task pane

    private var linkedTask: FastplayTask? {
        guard let taskID = sessions.session(id: sessionID)?.taskLink?.taskID else { return nil }
        for column in boardStore.board?.columns ?? [] {
            if let task = column.tasks.first(where: { $0.id == taskID }) { return task }
        }
        return nil
    }

    @ViewBuilder
    private var taskPane: some View {
        let link = sessions.session(id: sessionID)?.taskLink
        if let task = linkedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        FQStatusPill(text: task.shortCode, hue: .gray)
                        if let priority = task.priorityValue {
                            PriorityBadge(priority: priority)
                        }
                        Spacer(minLength: 0)
                    }

                    Text(task.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FQTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !description.isEmpty {
                        Text(MentionMarkup.styled(description))
                            .font(FQTheme.fontBody)
                            .foregroundStyle(FQTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let labels = task.labels, !labels.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(labels) { label in
                                LabelChipView(label: label, compact: true)
                            }
                        }
                    }

                    if let assignees = task.assignees, !assignees.isEmpty {
                        HStack(spacing: 6) {
                            Text("Assignees")
                                .font(FQTheme.fontCaption)
                                .foregroundStyle(FQTheme.textSecondary)
                            AvatarStack(users: assignees, size: 18)
                        }
                    }

                    FQButton(title: "Open full details", systemImage: "arrow.up.forward.square", size: .small) {
                        onOpenTaskDetail(task)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        } else if let title = link?.taskTitle, !title.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let code = link?.taskShortCode {
                    FQStatusPill(text: code, hue: .gray)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FQTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Switch to this task's project to load its full details.")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textSecondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.document")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(FQTheme.textTertiary)
                Text("No linked task")
                    .font(FQTheme.fontBodyMedium)
                    .foregroundStyle(FQTheme.textPrimary)
                Text("This agent wasn't started from a board task.")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The inspector's mini-rail sections.
enum InspectorPane: String, CaseIterable, Identifiable {
    case task
    case terminal
    case files
    case git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .task: return "Task"
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .git: return "Changes"
        }
    }

    var systemImage: String {
        switch self {
        case .task: return "text.document"
        case .terminal: return "terminal"
        case .files: return "folder"
        case .git: return "arrow.triangle.branch"
        }
    }
}
