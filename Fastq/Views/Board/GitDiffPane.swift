import SwiftUI
import AppKit

// MARK: - Diff line model

/// One rendered line of a unified diff.
struct ProjectDiffLine: Identifiable, Hashable {
    enum Kind {
        case fileHeader
        case hunk
        case added
        case removed
        case context
        case meta
    }

    let id: Int
    let kind: Kind
    let text: String

    var foreground: Color {
        switch kind {
        case .fileHeader: return FQTheme.textPrimary
        case .hunk: return FQTheme.accent
        case .added: return FQTheme.success
        case .removed: return FQTheme.danger
        case .context: return FQTheme.textSecondary
        case .meta: return FQTheme.textTertiary
        }
    }

    var background: Color {
        switch kind {
        case .added: return FQTheme.success.opacity(0.12)
        case .removed: return FQTheme.danger.opacity(0.12)
        case .hunk: return FQTheme.surfaceSecondary
        default: return .clear
        }
    }

    var weight: Font.Weight {
        switch kind {
        case .fileHeader: return .semibold
        case .hunk: return .medium
        default: return .regular
        }
    }

    /// Rows past this are dropped — the nested scroll views realize every row,
    /// so a huge diff would otherwise stall the pane.
    static let lineLimit = 4000

    /// Parses unified diff text into coloured lines.
    static func parse(_ diff: String) -> [ProjectDiffLine] {
        guard !diff.isEmpty else { return [] }
        var result: [ProjectDiffLine] = []
        var index = 0
        var truncated = false
        for raw in diff.components(separatedBy: "\n") {
            if index >= lineLimit {
                truncated = true
                break
            }
            let kind: Kind
            if raw.hasPrefix("diff --git") {
                kind = .fileHeader
            } else if raw.hasPrefix("@@") {
                kind = .hunk
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---") {
                kind = .meta
            } else if raw.hasPrefix("index ") || raw.hasPrefix("new file")
                        || raw.hasPrefix("deleted file") || raw.hasPrefix("similarity index")
                        || raw.hasPrefix("rename ") || raw.hasPrefix("old mode")
                        || raw.hasPrefix("new mode") || raw.hasPrefix("Binary files") {
                kind = .meta
            } else if raw.hasPrefix("+") {
                kind = .added
            } else if raw.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            result.append(ProjectDiffLine(id: index, kind: kind, text: raw))
            index += 1
        }
        // Drop a single trailing blank line from the terminating newline.
        if !truncated, let last = result.last, last.text.isEmpty {
            result.removeLast()
        }
        if truncated {
            result.append(ProjectDiffLine(
                id: index,
                kind: .meta,
                text: "… diff truncated at \(lineLimit) lines"
            ))
        }
        return result
    }
}

// MARK: - Model

/// Loads `git status` plus the unified diff for the selected path.
@MainActor
final class GitDiffModel: ObservableObject {
    @Published private(set) var rootPath: String?
    @Published private(set) var isRepo = false
    @Published private(set) var branch: String?
    @Published private(set) var changes: [ProjectGitChange] = []
    @Published private(set) var diffLines: [ProjectDiffLine] = []
    @Published private(set) var diffText = ""
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false

    /// nil means "whole repository".
    @Published private(set) var selectedPath: String?
    @Published var showStaged = false {
        didSet {
            guard showStaged != oldValue else { return }
            refresh()
        }
    }

    private var loadTask: Task<Void, Never>?
    private var generation = 0

    init(rootPath: String? = nil) {
        if let rootPath {
            setRoot(rootPath)
        }
    }

    var stagedCount: Int { changes.filter { $0.isStaged }.count }
    var unstagedCount: Int { changes.count - stagedCount }

    /// Changes for the active staged/unstaged filter.
    var visibleChanges: [ProjectGitChange] {
        showStaged ? changes.filter { $0.isStaged } : changes
    }

    var isClean: Bool { isRepo && changes.isEmpty }

    /// Points the pane at a new folder. Tolerates nil and missing paths.
    func setRoot(_ path: String?) {
        let normalized = Self.normalize(path)
        guard normalized != rootPath else { return }
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        rootPath = normalized
        isRepo = false
        branch = nil
        changes = []
        selectedPath = nil
        diffLines = []
        diffText = ""
        isLoading = false
        hasLoadedOnce = false
        if normalized != nil {
            refresh()
        }
    }

    private nonisolated static func normalize(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return expanded
    }

    /// Selects a file to diff. Passing nil (or the current selection) diffs the
    /// whole repository.
    func select(_ path: String?) {
        if selectedPath == path {
            selectedPath = nil
        } else {
            selectedPath = path
        }
        reloadDiff()
    }

    /// Re-reads status + diff. Safe to call repeatedly (used for polling).
    func refresh() {
        guard let root = rootPath else { return }
        loadTask?.cancel()
        generation &+= 1
        let token = generation
        let path = selectedPath
        let staged = showStaged
        isLoading = true
        loadTask = Task { [weak self] in
            let repo = await GitService.isRepo(root)
            guard !Task.isCancelled else { return }
            guard repo else {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.isRepo = false
                    self.branch = nil
                    self.changes = []
                    self.diffLines = []
                    self.diffText = ""
                    self.isLoading = false
                    self.hasLoadedOnce = true
                }
                return
            }
            let branch = await GitService.branch(in: root)
            let status = await GitService.status(in: root)
            let diff = await GitService.diff(path: path, staged: staged, in: root) ?? ""
            guard !Task.isCancelled else { return }
            let lines = ProjectDiffLine.parse(diff)
            await MainActor.run { [weak self] in
                guard let self, self.generation == token, self.rootPath == root else { return }
                self.isRepo = true
                self.branch = branch
                self.changes = status
                // Keep the selection only while the file still has changes.
                if let path, !status.contains(where: { $0.path == path }) {
                    self.selectedPath = nil
                }
                self.diffText = diff
                self.diffLines = lines
                self.isLoading = false
                self.hasLoadedOnce = true
            }
        }
    }

    /// Reloads only the diff body for the current selection.
    private func reloadDiff() {
        guard let root = rootPath, isRepo else { return }
        loadTask?.cancel()
        generation &+= 1
        let token = generation
        let path = selectedPath
        let staged = showStaged
        isLoading = true
        loadTask = Task { [weak self] in
            let diff = await GitService.diff(path: path, staged: staged, in: root) ?? ""
            guard !Task.isCancelled else { return }
            let lines = ProjectDiffLine.parse(diff)
            await MainActor.run { [weak self] in
                guard let self, self.generation == token, self.rootPath == root else { return }
                self.diffText = diff
                self.diffLines = lines
                self.isLoading = false
            }
        }
    }

    func copyDiff() {
        guard !diffText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diffText, forType: .string)
    }

    func url(for change: ProjectGitChange) -> URL? {
        guard let rootPath else { return nil }
        return URL(fileURLWithPath: rootPath).appendingPathComponent(change.path)
    }
}

// MARK: - Pane

/// Source-control pane: changed files on top, unified diff below.
struct GitDiffPane: View {
    @ObservedObject private var model: GitDiffModel

    init(model: GitDiffModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.rootPath == nil {
                noProjectState
            } else if model.hasLoadedOnce && !model.isRepo {
                header
                Divider().opacity(0.6)
                notARepoState
            } else {
                header
                Divider().opacity(0.6)
                changesList
                Divider().opacity(0.6)
                diffBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FQTheme.background)
        .task(id: model.rootPath) {
            // Keep git status fresh while the pane is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                model.refresh()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FQTheme.accent)
            Text(model.branch ?? "Source Control")
                .font(FQTheme.fontSmall.weight(.semibold))
                .foregroundStyle(FQTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.branch.map { "Branch \($0)" } ?? "Source Control")

            if model.isRepo, !model.changes.isEmpty {
                FQBadge(text: "\(model.changes.count)", tone: .neutral)
            }

            Spacer(minLength: FQTheme.space1)

            stagedToggle

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }

            FQIconButton(
                systemImage: "doc.on.doc",
                size: 20,
                iconSize: 10,
                help: "Copy diff",
                isDisabled: model.diffText.isEmpty
            ) {
                model.copyDiff()
            }

            FQIconButton(
                systemImage: "arrow.clockwise",
                size: 20,
                iconSize: 10,
                help: "Refresh changes"
            ) {
                model.refresh()
            }
        }
        .padding(.horizontal, FQTheme.space3)
        .padding(.vertical, 6)
    }

    private var stagedToggle: some View {
        HStack(spacing: 0) {
            segment(title: "All", isActive: !model.showStaged, count: model.changes.count) {
                model.showStaged = false
            }
            segment(title: "Staged", isActive: model.showStaged, count: model.stagedCount) {
                model.showStaged = true
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                .fill(FQTheme.surfaceSecondary)
        )
        .accessibilityLabel("Diff scope")
    }

    private func segment(title: String, isActive: Bool, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(FQTheme.fontCaption.weight(.semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(isActive ? FQTheme.textSecondary : FQTheme.textTertiary)
                }
            }
            .foregroundStyle(isActive ? FQTheme.textPrimary : FQTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: FQTheme.radiusSmall - 2, style: .continuous)
                    .fill(isActive ? FQTheme.surface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) changes")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: Changed files

    private var changesList: some View {
        Group {
            let items = model.visibleChanges
            if items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text(model.showStaged ? "Nothing staged" : "No changes")
                        .font(FQTheme.fontSmall)
                }
                .foregroundStyle(FQTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, FQTheme.space3)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { change in
                            GitChangeRowView(
                                change: change,
                                isSelected: model.selectedPath == change.path,
                                onSelect: { model.select(change.path) },
                                fileURL: model.url(for: change)
                            )
                        }
                    }
                    .padding(.horizontal, FQTheme.space2)
                    .padding(.vertical, 5)
                }
                .frame(minHeight: 60, maxHeight: 180)
            }
        }
    }

    // MARK: Diff

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            diffCaption
            if model.diffLines.isEmpty {
                emptyDiffState
            } else {
                GeometryReader { proxy in
                    ScrollView(.vertical) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(model.diffLines) { line in
                                    Text(line.text.isEmpty ? " " : line.text)
                                        .font(FQTheme.fontMono.weight(line.weight))
                                        .foregroundStyle(line.foreground)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, FQTheme.space2)
                                        .padding(.vertical, 0.5)
                                        .frame(minWidth: max(proxy.size.width, 1), alignment: .leading)
                                        .background(line.background)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .background(FQTheme.codeBackground)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var diffCaption: some View {
        HStack(spacing: 5) {
            Image(systemName: model.selectedPath == nil ? "square.stack.3d.up" : "doc.text")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FQTheme.textTertiary)
            Text(model.selectedPath ?? "All changes")
                .font(FQTheme.fontCaption.weight(.medium))
                .foregroundStyle(FQTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if model.selectedPath != nil {
                Button {
                    model.select(nil)
                } label: {
                    Text("Show all")
                        .font(FQTheme.fontCaption.weight(.medium))
                        .foregroundStyle(FQTheme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show diff for all changed files")
            }
        }
        .padding(.horizontal, FQTheme.space3)
        .padding(.vertical, 5)
        .help(model.selectedPath ?? "All changes")
    }

    // MARK: Empty states

    private var emptyDiffState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.isClean ? "checkmark.seal" : "text.alignleft")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)
            Text(model.isClean ? "No changes" : "Nothing to show")
                .font(FQTheme.fontBodyMedium)
                .foregroundStyle(FQTheme.textSecondary)
            Text(model.isClean
                 ? "The working tree is clean."
                 : (model.showStaged ? "Stage a change to see its diff." : "Select a changed file to see its diff."))
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FQTheme.space4)
    }

    private var notARepoState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)
            Text("Not a git repository")
                .font(FQTheme.fontBodyMedium)
                .foregroundStyle(FQTheme.textSecondary)
            Text("Run git init in this folder to track changes here.")
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FQTheme.space4)
    }

    private var noProjectState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)
            Text("No project folder")
                .font(FQTheme.fontBodyMedium)
                .foregroundStyle(FQTheme.textSecondary)
            Text("Pick a local folder for this project to see its git changes.")
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FQTheme.space4)
    }
}

// MARK: - Change row

private struct GitChangeRowView: View {
    let change: ProjectGitChange
    let isSelected: Bool
    let onSelect: () -> Void
    let fileURL: URL?

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Text(change.badge)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.badgeColor)
                    .frame(width: 12)
                Text(change.fileName)
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                    .fill(isSelected ? FQTheme.surfaceHover : (isHovering ? FQTheme.surfaceSecondary : Color.clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(FQTheme.accent)
                        .frame(width: 2)
                        .padding(.vertical, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(change.describedStatus) — \(change.path)")
        .accessibilityLabel("\(change.describedStatus) \(change.path)")
        .accessibilityHint("Shows the diff for this file")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            if let fileURL {
                ProjectFileContextMenu(url: fileURL, onOpen: { NSWorkspace.shared.open(fileURL) })
            }
            Button("Copy Repo Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
        }
    }
}
