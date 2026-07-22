import SwiftUI

/// Launcher Projects mode content: recent tasks for the selected Fastplay project.
struct BoardModeView: View {
    @ObservedObject var store: BoardStore
    @ObservedObject var auth: FastplayAuthStore
    var onSignIn: () -> Void
    var onOpenBoards: () -> Void
    var onStartAgent: ((column: FastplayColumn, task: FastplayTask)) -> Void = { _ in }
    var onOpenTask: (FastplayTask) -> Void = { _ in }
    var onNewTask: () -> Void = {}

    /// All tasks vs only ones assigned to me.
    @State private var showMineOnly = false

    private var visibleTasks: [(column: FastplayColumn, task: FastplayTask)] {
        guard showMineOnly, let me = auth.user?.id else { return store.flatTasks }
        return store.flatTasks.filter { item in
            item.task.assignees?.contains { $0.id == me } ?? false
        }
    }

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                signedOut
            } else if store.isLoading && store.board == nil && store.workspaces.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedProject == nil {
                emptyProject
            } else {
                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedOut: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Create project tasks")
                .font(.headline)
            Text("Sign in to pick a workspace and project, then submit a task title with optional attachments.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Sign in…", action: onSignIn)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var emptyProject: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "folder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No project selected")
                .font(.headline)
            Text("Choose a workspace and project in the chips above, or open Boards to create one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open Boards", action: onOpenBoards)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(store.selectedProject?.name.uppercased() ?? "TASKS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                filterChip(title: "All", active: !showMineOnly) { showMineOnly = false }
                filterChip(title: "Mine", active: showMineOnly) { showMineOnly = true }
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Button(action: onNewTask) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("New task")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Create a task with description, priority, labels, and attachments")
                .accessibilityLabel("New task")
                Button("Open board", action: onOpenBoards)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if visibleTasks.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text(showMineOnly ? "Nothing assigned to you here" : "No tasks yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text(showMineOnly
                         ? "Tasks where you're an assignee show up in this filter."
                         : "Type a title above and press Return — or click “New task” for the full form.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleTasks, id: \.task.id) { item in
                            taskRow(column: item.column, task: item.task)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func filterChip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? FQTheme.accent : FQTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    active ? FQTheme.accent.opacity(0.12) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) tasks\(active ? ", selected" : "")")
    }

    private func taskRow(column: FastplayColumn, task: FastplayTask) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(boardColumnTint(column))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(task.isCompleted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(column.name)
                    DueDateBadge(dueDate: task.dueDate, completed: task.isCompleted)
                    MetaCountBadge(systemImage: "paperclip", count: task.attachmentsCount ?? 0, help: "Attachments")
                    MetaCountBadge(systemImage: "text.bubble", count: task.commentsCount ?? 0, help: "Comments")
                    MetaCountBadge(systemImage: "checklist", count: task.subtasksCount ?? 0, help: "Subtasks")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let labels = task.labels, !labels.isEmpty {
                HStack(spacing: -3) {
                    ForEach(labels.prefix(3)) { label in
                        Circle()
                            .fill(Color(hexString: label.color))
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5))
                            .help(label.name)
                    }
                }
            }
            if let assignees = task.assignees, !assignees.isEmpty {
                AvatarStack(users: assignees, size: 16)
            }
            if let priority = task.priorityValue {
                PriorityBadge(priority: priority, compact: true)
            }
            Button {
                onStartAgent((column, task))
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Start agent")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenTask(task)
        }
        .contextMenu {
            Button("Open details") {
                onOpenTask(task)
            }
            Button("Start agent") {
                onStartAgent((column, task))
            }
        }
        .accessibilityLabel("Task \(task.title), column \(column.name)")
    }
}
