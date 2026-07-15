import SwiftUI

/// Launcher Projects mode content: recent tasks for the selected Fastplay project.
struct BoardModeView: View {
    @ObservedObject var store: BoardStore
    @ObservedObject var auth: FastplayAuthStore
    var onSignIn: () -> Void
    var onOpenBoards: () -> Void

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
            HStack {
                Text(store.selectedProject?.name.uppercased() ?? "TASKS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Button("Open board", action: onOpenBoards)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if store.flatTasks.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text("No tasks yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Type a title above and press Return to create one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.flatTasks, id: \.task.id) { item in
                            taskRow(column: item.column, task: item.task)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func taskRow(column: FastplayColumn, task: FastplayTask) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(columnDot(column))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(column.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let priority = task.priority, !priority.isEmpty {
                Text(priority)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func columnDot(_ column: FastplayColumn) -> Color {
        switch column.name.lowercased() {
        case "todo": return Color.secondary.opacity(0.7)
        case "in progress", "in_progress": return Color.accentColor
        case "done": return Color.green.opacity(0.75)
        default: return Color.secondary.opacity(0.5)
        }
    }
}
