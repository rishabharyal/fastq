import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Full task detail — Linear-style layout: main content (title, description,
/// subtasks, attachments, comments/activity) plus a properties sidebar
/// (status, priority, people, labels, dates).
struct TaskDetailView: View {
    @ObservedObject var boardStore: BoardStore
    @StateObject private var detail: TaskDetailStore
    var onClose: () -> Void
    var onStartAgent: ((FastplayTask) -> Void)?

    @State private var title: String
    @State private var descriptionText: String
    @State private var savedDescription: String
    @State private var newComment = ""
    @State private var replyTarget: FastplayComment?
    @State private var newSubtask = ""
    @State private var assigneeQuery = ""
    @State private var assigneeResults: [FastplayUser] = []
    @State private var assigneeSearchTask: Task<Void, Never>?
    @State private var confirmDelete = false
    @State private var isDropTargeted = false
    @State private var pasteMonitor: Any?

    private enum DetailTab: String, CaseIterable {
        case comments = "Comments"
        case activity = "Activity"
    }
    @State private var tab: DetailTab = .comments

    init(
        task: FastplayTask,
        boardStore: BoardStore,
        onClose: @escaping () -> Void,
        onStartAgent: ((FastplayTask) -> Void)? = nil
    ) {
        self.boardStore = boardStore
        self.onClose = onClose
        self.onStartAgent = onStartAgent
        _title = State(initialValue: task.title)
        _descriptionText = State(initialValue: task.description ?? "")
        _savedDescription = State(initialValue: task.description ?? "")
        _detail = StateObject(wrappedValue: TaskDetailStore(
            task: task,
            context: TaskDetailStore.Context(
                workspace: boardStore.selectedWorkspace?.routeKey ?? "",
                workspaceID: boardStore.selectedWorkspaceID,
                project: boardStore.selectedProject?.routeKey ?? "",
                columns: boardStore.board?.columns ?? []
            )
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: FQTheme.space5) {
                        titleSection
                        descriptionSection
                        subtasksSection
                        attachmentsSection
                        conversationSection
                    }
                    .padding(FQTheme.space5)
                }
                .frame(maxWidth: .infinity)

                Divider().opacity(0.6)

                sidebar
            }
        }
        .frame(width: 800)
        .frame(minHeight: 500, maxHeight: 700)
        .background(FQTheme.surface)
        .task {
            detail.onChanged = { [weak boardStore] in
                Task { await boardStore?.refreshBoard() }
            }
            await detail.load()
            title = detail.task.title
            descriptionText = detail.task.description ?? ""
            savedDescription = descriptionText
            await boardStore.refreshLabels()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear(perform: installPasteMonitor)
        .onDisappear(perform: removePasteMonitor)
        .alert("Task", isPresented: Binding(
            get: { detail.errorMessage != nil },
            set: { if !$0 { detail.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { detail.errorMessage = nil }
        } message: {
            Text(detail.errorMessage ?? "")
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete) {
            Button("Delete task", role: .destructive) {
                Task {
                    if await detail.deleteTask() { onClose() }
                }
            }
        } message: {
            Text("“\(detail.task.title)” and its subtasks, comments, and attachments will be removed.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FQTheme.space2) {
            FQStatusPill(text: detail.task.shortCode, hue: .gray)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(FQTheme.textTertiary)
            Text(currentColumnName)
                .font(FQTheme.fontSmall.weight(.medium))
                .foregroundStyle(FQTheme.textSecondary)
            if detail.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let onStartAgent {
                FQButton(title: "Start agent", systemImage: "bolt.fill", variant: .primary, size: .small) {
                    onStartAgent(detail.task)
                }
                .help("Start a coding agent on this task")
            }
            FQIconButton(
                systemImage: detail.isWatching ? "eye.fill" : "eye",
                size: 26, iconSize: 12,
                tint: detail.isWatching ? FQTheme.accent : nil,
                help: detail.isWatching ? "Stop watching" : "Watch this task"
            ) {
                Task { await detail.toggleWatch() }
            }
            FQIconButton(systemImage: "trash", size: 26, iconSize: 12, help: "Delete task") {
                confirmDelete = true
            }
            FQIconButton(systemImage: "xmark", size: 26, iconSize: 11, help: "Close") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, FQTheme.space4)
        .padding(.vertical, 10)
    }

    // MARK: - Main column

    private var titleSection: some View {
        TextField("Title", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 19, weight: .bold))
            .lineLimit(1...4)
            .onSubmit {
                Task { await detail.saveTitle(title) }
            }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FQSectionTitle(text: "Description")
                Spacer()
                if descriptionText != savedDescription {
                    FQButton(title: "Save", variant: .primary, size: .small) {
                        Task {
                            await detail.saveDescription(descriptionText)
                            savedDescription = descriptionText
                        }
                    }
                }
            }
            MentionTextEditor(
                text: $descriptionText,
                placeholder: "No description — click to add one…",
                workspaceID: boardStore.selectedWorkspaceID,
                projectID: boardStore.selectedProjectID,
                minHeight: 80,
                maxHeight: 200
            )
        }
    }

    // MARK: - Subtasks (progress header + checklist)

    private var subtasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: FQTheme.space2) {
                FQSectionTitle(text: "Subtasks")
                if !detail.subtasks.isEmpty {
                    Text("\(completedSubtasks) of \(detail.subtasks.count)")
                        .font(FQTheme.fontCaption.weight(.medium))
                        .foregroundStyle(FQTheme.textSecondary)
                    subtaskProgressBar
                        .frame(width: 90)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(detail.subtasks) { subtask in
                    subtaskRow(subtask)
                }
            }

            FQTextField(placeholder: "Add a subtask…", text: $newSubtask, onSubmit: {
                let title = newSubtask
                newSubtask = ""
                Task { await detail.addSubtask(title: title) }
            })
            .frame(maxWidth: 340)
        }
    }

    private var subtaskProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FQTheme.surfaceSecondary)
                Capsule()
                    .fill(FQTheme.success)
                    .frame(width: proxy.size.width * subtaskProgress)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.2), value: subtaskProgress)
    }

    private var subtaskProgress: CGFloat {
        guard !detail.subtasks.isEmpty else { return 0 }
        return CGFloat(completedSubtasks) / CGFloat(detail.subtasks.count)
    }

    private var completedSubtasks: Int {
        detail.subtasks.filter(\.isCompleted).count
    }

    private func subtaskRow(_ subtask: FastplayTask) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await detail.toggleSubtask(subtask) }
            } label: {
                Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(subtask.isCompleted ? FQTheme.success : FQTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(subtask.isCompleted ? "Mark incomplete" : "Mark complete")
            Text(subtask.title)
                .font(FQTheme.fontBody)
                .strikethrough(subtask.isCompleted)
                .foregroundStyle(subtask.isCompleted ? FQTheme.textSecondary : FQTheme.textPrimary)
            Spacer()
            if let p = subtask.priorityValue {
                PriorityBadge(priority: p, compact: true)
            }
            FQIconButton(systemImage: "xmark", size: 18, iconSize: 8, help: "Delete subtask") {
                Task { await detail.deleteSubtask(subtask) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(FQTheme.background, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FQSectionTitle(text: "Attachments\(detail.attachments.isEmpty ? "" : " · \(detail.attachments.count)")")
                Spacer()
                FQButton(title: "Add files…", systemImage: "paperclip", variant: .outline, size: .small) {
                    pickFiles()
                }
            }
            if detail.attachments.isEmpty {
                Text("Drop files anywhere on this card — or paste with ⌘V.")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textSecondary)
            }
            ForEach(detail.attachments) { attachment in
                attachmentRow(attachment)
            }
        }
        .padding(isDropTargeted ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: FQTheme.radiusMedium, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? FQTheme.focusRing : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [4])
                )
        )
    }

    private func attachmentRow(_ attachment: FastplayAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachmentIcon(attachment.name))
                .font(.system(size: 12))
                .foregroundStyle(FQTheme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(FQTheme.fontBodyMedium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let size = attachment.sizeLabel {
                        Text(size)
                    }
                    if let when = FastplayDates.relative(attachment.createdAt) {
                        Text(when)
                    }
                    if let who = attachment.uploadedBy?.name, !who.isEmpty {
                        Text("by \(who)")
                    }
                }
                .font(FQTheme.fontCaption)
                .foregroundStyle(FQTheme.textSecondary)
            }
            Spacer()
            if detail.busyAttachmentIDs.contains(attachment.id) {
                ProgressView().controlSize(.mini)
            } else {
                FQIconButton(systemImage: "eye", size: 22, iconSize: 11, help: "Open") {
                    openAttachment(attachment)
                }
                FQIconButton(systemImage: "square.and.arrow.down", size: 22, iconSize: 11, help: "Save…") {
                    saveAttachment(attachment)
                }
                FQIconButton(systemImage: "trash", size: 22, iconSize: 11, help: "Delete") {
                    Task { await detail.deleteAttachment(attachment) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(FQTheme.background, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
    }

    // MARK: - Comments / Activity tabs

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: FQTheme.space3) {
            HStack(spacing: 4) {
                ForEach(DetailTab.allCases, id: \.self) { candidate in
                    let count = candidate == .comments ? detail.comments.count : detail.activities.count
                    Button {
                        tab = candidate
                    } label: {
                        Text(count > 0 ? "\(candidate.rawValue) \(count)" : candidate.rawValue)
                            .font(FQTheme.fontSmall.weight(.semibold))
                            .foregroundStyle(tab == candidate ? FQTheme.textPrimary : FQTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                tab == candidate ? FQTheme.surfaceSecondary : .clear,
                                in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(candidate.rawValue) tab\(tab == candidate ? ", selected" : "")")
                }
                Spacer()
            }

            if tab == .comments {
                commentsList
            } else {
                activityList
            }
        }
    }

    private var commentsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(detail.comments) { comment in
                commentRow(comment, indent: 0)
                ForEach(comment.replies ?? []) { reply in
                    commentRow(reply, indent: 1)
                }
            }
            if detail.comments.isEmpty {
                Text("No comments yet.")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textSecondary)
            }
            if let replyTarget {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                    Text("Replying to \(replyTarget.author?.name ?? "comment")")
                        .font(FQTheme.fontSmall)
                    FQIconButton(systemImage: "xmark.circle.fill", size: 18, iconSize: 9, help: "Cancel reply") {
                        self.replyTarget = nil
                    }
                }
                .foregroundStyle(FQTheme.textSecondary)
            }
            HStack(alignment: .top, spacing: 8) {
                MentionTextEditor(
                    text: $newComment,
                    placeholder: "Write a comment…  @ people · # tasks",
                    workspaceID: boardStore.selectedWorkspaceID,
                    projectID: boardStore.selectedProjectID,
                    compact: true,
                    onSubmit: sendComment
                )
                FQButton(title: "Send", variant: .primary, size: .small, action: sendComment)
                    .opacity(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
        }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(detail.activities) { activity in
                HStack(spacing: 8) {
                    Circle()
                        .fill(FQTheme.textTertiary)
                        .frame(width: 5, height: 5)
                    Text(activityLine(activity))
                        .font(FQTheme.fontSmall)
                    Spacer()
                    if let when = FastplayDates.relative(activity.createdAt) {
                        Text(when)
                            .font(FQTheme.fontCaption)
                            .foregroundStyle(FQTheme.textTertiary)
                    }
                }
            }
            if detail.activities.isEmpty {
                Text("No activity yet.")
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textSecondary)
            }
        }
    }

    private func sendComment() {
        let body = newComment
        let parent = replyTarget?.id
        newComment = ""
        replyTarget = nil
        Task { await detail.addComment(body, parentID: parent) }
    }

    private func commentRow(_ comment: FastplayComment, indent: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarBubble(name: comment.author?.name ?? "?", size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.author?.name ?? "Unknown")
                        .font(FQTheme.fontSmall.weight(.semibold))
                    if let when = FastplayDates.relative(comment.createdAt) {
                        Text(when)
                            .font(FQTheme.fontCaption)
                            .foregroundStyle(FQTheme.textTertiary)
                    }
                    Spacer()
                    if indent == 0 {
                        Button("Reply") {
                            replyTarget = comment
                        }
                        .buttonStyle(.plain)
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textSecondary)
                    }
                    FQIconButton(systemImage: "trash", size: 18, iconSize: 9, help: "Delete comment") {
                        Task { await detail.deleteComment(comment) }
                    }
                }
                Text(MentionMarkup.styled(comment.body))
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.leading, CGFloat(indent) * 24)
        .background(FQTheme.background, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
    }

    private func activityLine(_ activity: FastplayActivity) -> String {
        let action = activity.type
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        if let actor = activity.actor?.name, !actor.isEmpty {
            return "\(actor) — \(action)"
        }
        return action
    }

    // MARK: - Properties sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FQTheme.space4) {
                propertyRow(label: "Status") { columnMenu }
                propertyRow(label: "Completion") { completeToggle }
                propertyRow(label: "Priority") { priorityMenu }
                propertyRow(label: "Assignees") { assigneesControl }
                propertyRow(label: "Labels") { labelsControl }
                propertyRow(label: "Start date") {
                    dateControl(value: detail.task.startDate) { date in
                        Task { await detail.setStartDate(date) }
                    }
                }
                propertyRow(label: "Due date") {
                    dateControl(value: detail.task.dueDate) { date in
                        Task { await detail.setDueDate(date) }
                    }
                }
                if let reporter = detail.task.reporter {
                    propertyRow(label: "Reporter") {
                        HStack(spacing: 6) {
                            AvatarBubble(name: reporter.name.isEmpty ? reporter.email : reporter.name, size: 18)
                            Text(reporter.name)
                                .font(FQTheme.fontSmall)
                                .lineLimit(1)
                        }
                    }
                }
                if let created = FastplayDates.relative(detail.task.createdAt) {
                    propertyRow(label: "Created") {
                        Text(created)
                            .font(FQTheme.fontSmall)
                            .foregroundStyle(FQTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(FQTheme.space4)
        }
        .frame(width: 224)
        .background(FQTheme.background)
    }

    private func propertyRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(FQTheme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnMenu: some View {
        Menu {
            ForEach(sortedColumns) { column in
                Button {
                    Task { await detail.move(toColumn: column.id) }
                } label: {
                    if column.id == detail.task.boardColumnID {
                        Label(column.name, systemImage: "checkmark")
                    } else {
                        Text(column.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(currentColumnTint)
                    .frame(width: 7, height: 7)
                Text(currentColumnName)
                    .font(FQTheme.fontSmall.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(FQTheme.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(FQTheme.surfaceSecondary, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move to another column")
    }

    private var completeToggle: some View {
        Button {
            Task { await detail.setStatus(detail.task.isCompleted ? "todo" : "done") }
        } label: {
            Label(
                detail.task.isCompleted ? "Completed" : "Mark complete",
                systemImage: detail.task.isCompleted ? "checkmark.circle.fill" : "circle"
            )
            .font(FQTheme.fontSmall.weight(.medium))
            .foregroundStyle(detail.task.isCompleted ? FQTheme.success : FQTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Status: \(detail.task.status ?? "todo")")
    }

    private var priorityMenu: some View {
        Menu {
            Button("None") { Task { await detail.setPriority(nil) } }
            ForEach(TaskPriority.allCases) { p in
                Button {
                    Task { await detail.setPriority(p) }
                } label: {
                    Label(p.displayName, systemImage: p.systemImage)
                }
            }
        } label: {
            if let p = detail.task.priorityValue {
                PriorityBadge(priority: p)
            } else {
                Text("Set priority")
                    .font(FQTheme.fontCaption.weight(.medium))
                    .foregroundStyle(FQTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(FQTheme.surfaceSecondary, in: Capsule())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Priority")
    }

    private var assigneesControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(detail.task.assignees ?? []) { user in
                HStack(spacing: 6) {
                    AvatarBubble(name: user.name.isEmpty ? user.email : user.name, size: 18)
                    Text(user.name.isEmpty ? user.email : user.name)
                        .font(FQTheme.fontSmall)
                        .lineLimit(1)
                    Spacer()
                    FQIconButton(systemImage: "xmark", size: 16, iconSize: 7.5, help: "Unassign \(user.name)") {
                        Task { await detail.removeAssignee(user) }
                    }
                }
            }
            FQTextField(placeholder: "Add someone…", text: $assigneeQuery)
                .onChange(of: assigneeQuery) { _, query in
                    searchAssignees(query)
                }
            ForEach(assigneeResults.prefix(4)) { user in
                Button {
                    Task { await detail.addAssignee(user) }
                    assigneeQuery = ""
                    assigneeResults = []
                } label: {
                    HStack(spacing: 6) {
                        AvatarBubble(name: user.name.isEmpty ? user.email : user.name, size: 16)
                        Text(user.name)
                            .font(FQTheme.fontSmall)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(FQTheme.surfaceSecondary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var labelsControl: some View {
        FlowLayout(spacing: 5) {
            ForEach(boardStore.workspaceLabels) { label in
                let attached = detail.task.labels?.contains { $0.id == label.id } ?? false
                Button {
                    Task { await detail.toggleLabel(label) }
                } label: {
                    LabelChipView(label: label, compact: true)
                        .overlay(
                            Capsule().strokeBorder(
                                attached ? Color(hexString: label.color) : Color.clear,
                                lineWidth: 1.5
                            )
                        )
                        .opacity(attached ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label.name)\(attached ? ", attached" : "")")
            }
            if boardStore.workspaceLabels.isEmpty {
                Text("No labels yet")
                    .font(FQTheme.fontCaption)
                    .foregroundStyle(FQTheme.textSecondary)
            }
        }
    }

    private func dateControl(value: String?, onSet: @escaping (Date) -> Void) -> some View {
        DatePicker(
            "",
            selection: Binding(
                get: { FastplayDates.parse(value) ?? Date() },
                set: { onSet($0) }
            ),
            displayedComponents: .date
        )
        .datePickerStyle(.compact)
        .labelsHidden()
        .controlSize(.small)
        .opacity(value == nil ? 0.55 : 1)
        .help(value == nil ? "Not set — pick a date to set it" : "")
    }

    // MARK: - Shared helpers

    private var sortedColumns: [FastplayColumn] {
        detail.context.columns.sorted { $0.position < $1.position }
    }

    private var currentColumnName: String {
        detail.column?.name ?? detail.task.resolvedColumnName ?? "Column"
    }

    private var currentColumnTint: Color {
        detail.column.map(boardColumnTint) ?? .secondary
    }

    private func searchAssignees(_ query: String) {
        assigneeSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            assigneeResults = []
            return
        }
        assigneeSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let results = await detail.searchWorkspaceUsers(trimmed)
            guard !Task.isCancelled else { return }
            assigneeResults = results
        }
    }

    private func attachmentIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "zip": return "archivebox"
        case "txt", "md": return "doc.text"
        default: return "doc"
        }
    }

    /// Downloads to a temp file and opens it with the default app.
    private func openAttachment(_ attachment: FastplayAttachment) {
        Task {
            guard let data = await detail.attachmentData(attachment) else { return }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("fastq-attachments", isDirectory: true)
                .appendingPathComponent(attachment.id, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(attachment.name)
                try data.write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                detail.errorMessage = error.localizedDescription
            }
        }
    }

    private func saveAttachment(_ attachment: FastplayAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.name
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            guard let data = await detail.attachmentData(attachment) else { return }
            do {
                try data.write(to: target)
            } catch {
                detail.errorMessage = error.localizedDescription
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        Task { await detail.uploadAttachments(panel.urls) }
    }

    /// ⌘V with files or a screenshot on the clipboard uploads them as
    /// attachments; plain text falls through to the focused field.
    private func installPasteMonitor() {
        removePasteMonitor()
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == .command, event.charactersIgnoringModifiers == "v" else { return event }
            let files = PasteboardFiles.read()
            guard !files.isEmpty else { return event }
            Task { @MainActor in
                await detail.uploadAttachments(files)
            }
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor {
            NSEvent.removeMonitor(pasteMonitor)
            self.pasteMonitor = nil
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url {
                    Task { @MainActor in
                        await detail.uploadAttachments([url])
                    }
                }
            }
        }
        return handled
    }
}
