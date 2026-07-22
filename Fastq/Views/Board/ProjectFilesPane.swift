import SwiftUI
import AppKit

// MARK: - Node

/// One entry in the project file tree.
struct ProjectFileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// SF Symbol chosen from the file extension.
    var systemImage: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "swift", "m", "mm", "h", "c", "cpp", "rs", "go", "java", "kt", "rb", "py", "php":
            return "chevron.left.forwardslash.chevron.right"
        case "js", "jsx", "ts", "tsx", "vue", "svelte":
            return "curlybraces"
        case "json", "yml", "yaml", "toml", "plist", "xml", "ini", "env":
            return "list.bullet.rectangle"
        case "md", "markdown", "txt", "rst":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "heic", "webp", "icns", "pdf":
            return "photo"
        case "sh", "zsh", "bash", "fish":
            return "terminal"
        case "lock", "sum":
            return "lock.doc"
        case "css", "scss", "sass", "less":
            return "paintbrush"
        case "html", "htm":
            return "globe"
        case "zip", "gz", "tar", "dmg":
            return "shippingbox"
        default:
            return "doc"
        }
    }
}

// MARK: - Model

/// Lazy directory tree + debounced filename search for a project folder.
@MainActor
final class ProjectFilesModel: ObservableObject {
    @Published private(set) var rootPath: String?
    @Published var expanded: Set<String> = []
    @Published private(set) var children: [String: [ProjectFileNode]] = [:]
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var searchResults: [ProjectFileNode] = []
    @Published private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?

    /// Directories that are never worth walking.
    nonisolated static let skippedNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".venv", "venv",
        "__pycache__", ".next", "dist", "build.noindex", ".swiftpm",
        "Pods", ".gradle", "target", ".tox", ".mypy_cache", ".pytest_cache",
    ]

    init(rootPath: String? = nil) {
        if let rootPath {
            setRoot(rootPath)
        }
    }

    var rootName: String? {
        guard let rootPath else { return nil }
        return (rootPath as NSString).lastPathComponent
    }

    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Points the tree at a new folder. Tolerates nil and missing paths.
    func setRoot(_ path: String?) {
        let normalized = Self.normalize(path)
        guard normalized != rootPath else { return }
        searchTask?.cancel()
        searchTask = nil
        rootPath = normalized
        expanded = []
        children = [:]
        searchText = ""
        searchResults = []
        isSearching = false
        if let normalized {
            loadChildren(of: normalized)
        }
    }

    /// nil for nil/blank/non-existent directories.
    private nonisolated static func normalize(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expandedPath = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return expandedPath
    }

    // MARK: Tree

    func loadChildren(of path: String) {
        let url = URL(fileURLWithPath: path)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        let nodes = contents
            .compactMap { itemURL -> ProjectFileNode? in
                let name = itemURL.lastPathComponent
                if name == ".git" || name == ".DS_Store" { return nil }
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return ProjectFileNode(url: itemURL, isDirectory: isDir)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        children[path] = nodes
    }

    func toggle(_ node: ProjectFileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.id) {
            expanded.remove(node.id)
        } else {
            expanded.insert(node.id)
            if children[node.id] == nil {
                loadChildren(of: node.id)
            }
        }
    }

    func isExpanded(_ node: ProjectFileNode) -> Bool {
        expanded.contains(node.id)
    }

    func collapseAll() {
        expanded = []
    }

    /// Re-reads the root and every expanded directory.
    func refresh() {
        guard let rootPath else { return }
        loadChildren(of: rootPath)
        for path in expanded {
            loadChildren(of: path)
        }
        // Drop expansions whose directory disappeared.
        expanded = expanded.filter { children[$0] != nil }
        if isSearchActive { scheduleSearch() }
    }

    /// Flattened visible rows (node + indent depth) for the tree list.
    var visibleRows: [(node: ProjectFileNode, depth: Int)] {
        guard let rootPath else { return [] }
        var rows: [(node: ProjectFileNode, depth: Int)] = []
        func walk(_ path: String, depth: Int) {
            for node in children[path] ?? [] {
                rows.append((node: node, depth: depth))
                if node.isDirectory, expanded.contains(node.id) {
                    walk(node.id, depth: depth + 1)
                }
            }
        }
        walk(rootPath, depth: 0)
        return rows
    }

    /// Repo-relative display path for a node.
    func relativePath(for url: URL) -> String {
        guard let rootPath else { return url.path }
        let path = url.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
    }

    // MARK: Search (go to file)

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let rootPath else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self, rootPath] in
            try? await Task.sleep(nanoseconds: 180_000_000) // debounce typing
            guard !Task.isCancelled else { return }
            let results = await ProjectFilesModel.findFiles(matching: query, under: rootPath)
            guard !Task.isCancelled, let self else { return }
            guard self.rootPath == rootPath else { return }
            self.searchResults = results
            self.isSearching = false
        }
    }

    private nonisolated static func findFiles(matching query: String, under root: String) async -> [ProjectFileNode] {
        await Task.detached(priority: .userInitiated) {
            findFilesSync(matching: query, under: root)
        }.value
    }

    private nonisolated static func findFilesSync(matching query: String, under root: String) -> [ProjectFileNode] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var matches: [ProjectFileNode] = []
        var visited = 0
        let lowered = query.lowercased()
        for case let url as URL in enumerator {
            visited += 1
            if visited > 40_000 || matches.count >= 200 { break }
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir, skippedNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if !isDir, name.lowercased().contains(lowered) {
                matches.append(ProjectFileNode(url: url, isDirectory: false))
            }
        }
        // Prefix matches first, then shorter names — cheap "go to file" ranking.
        return matches.sorted { a, b in
            let ap = a.name.lowercased().hasPrefix(lowered)
            let bp = b.name.lowercased().hasPrefix(lowered)
            if ap != bp { return ap }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.url.path < b.url.path
        }
    }
}

// MARK: - Pane

/// Compact project file browser for the inspector panel.
struct ProjectFilesPane: View {
    @ObservedObject private var model: ProjectFilesModel
    private let onOpenFile: ((URL) -> Void)?

    init(model: ProjectFilesModel, onOpenFile: ((URL) -> Void)? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.onOpenFile = onOpenFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.rootPath == nil {
                emptyState
            } else {
                header
                searchField
                Divider().opacity(0.6)
                if model.isSearchActive {
                    searchList
                } else {
                    fileTree
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FQTheme.background)
    }

    private func open(_ url: URL) {
        if let onOpenFile {
            onOpenFile(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: FQTheme.space1 + 2) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FQTheme.accent)
            Text(model.rootName ?? "Files")
                .font(FQTheme.fontSmall.weight(.semibold))
                .foregroundStyle(FQTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.rootPath ?? "")
            Spacer(minLength: FQTheme.space1)
            if !model.expanded.isEmpty {
                FQIconButton(
                    systemImage: "chevron.up.chevron.down",
                    size: 20,
                    iconSize: 10,
                    help: "Collapse all"
                ) {
                    model.collapseAll()
                }
            }
            FQIconButton(
                systemImage: "arrow.clockwise",
                size: 20,
                iconSize: 10,
                help: "Refresh files"
            ) {
                model.refresh()
            }
        }
        .padding(.horizontal, FQTheme.space3)
        .padding(.top, FQTheme.space2)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            FQTextField(placeholder: "Go to file…", text: $model.searchText)
                .accessibilityLabel("Search files by name")
            if model.isSearchActive {
                FQIconButton(
                    systemImage: "xmark.circle.fill",
                    size: 20,
                    iconSize: 11,
                    help: "Clear search"
                ) {
                    model.searchText = ""
                }
            }
        }
        .padding(.horizontal, FQTheme.space3)
        .padding(.bottom, FQTheme.space2)
    }

    // MARK: Tree

    private var fileTree: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                let rows = model.visibleRows
                if rows.isEmpty {
                    placeholder("This folder is empty", systemImage: "tray")
                } else {
                    ForEach(rows, id: \.node.id) { row in
                        ProjectFileRow(
                            node: row.node,
                            depth: row.depth,
                            isExpanded: model.isExpanded(row.node),
                            onActivate: {
                                if row.node.isDirectory {
                                    model.toggle(row.node)
                                } else {
                                    open(row.node.url)
                                }
                            },
                            onOpen: { open(row.node.url) }
                        )
                    }
                }
            }
            .padding(.horizontal, FQTheme.space2)
            .padding(.vertical, 6)
        }
    }

    // MARK: Search results

    private var searchList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.searchResults.isEmpty {
                    placeholder(
                        model.isSearching ? "Searching…" : "No files match",
                        systemImage: model.isSearching ? "hourglass" : "magnifyingglass"
                    )
                } else {
                    ForEach(model.searchResults) { node in
                        ProjectSearchResultRow(
                            node: node,
                            relativePath: model.relativePath(for: node.url),
                            onOpen: { open(node.url) }
                        )
                    }
                }
            }
            .padding(.horizontal, FQTheme.space2)
            .padding(.vertical, 6)
        }
    }

    // MARK: Empty states

    private func placeholder(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(text)
                .font(FQTheme.fontSmall)
        }
        .foregroundStyle(FQTheme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, FQTheme.space4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)
            Text("No project folder")
                .font(FQTheme.fontBodyMedium)
                .foregroundStyle(FQTheme.textSecondary)
            Text("Pick a local folder for this project and its files show up here.")
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

// MARK: - Rows

private struct ProjectFileRow: View {
    let node: ProjectFileNode
    let depth: Int
    let isExpanded: Bool
    let onActivate: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 5) {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(FQTheme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: node.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(node.isDirectory ? FQTheme.accent : FQTheme.textSecondary)
                    .frame(width: 14)
                Text(node.name)
                    .font(FQTheme.fontSmall)
                    .foregroundStyle(FQTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 13 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                    .fill(isHovering ? FQTheme.surfaceSecondary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(node.name)
        .accessibilityLabel(node.isDirectory
                            ? "Folder \(node.name), \(isExpanded ? "expanded" : "collapsed")"
                            : "File \(node.name)")
        .accessibilityHint(node.isDirectory ? "Toggles this folder" : "Opens this file")
        .contextMenu {
            ProjectFileContextMenu(url: node.url, onOpen: node.isDirectory ? nil : onOpen)
        }
    }
}

private struct ProjectSearchResultRow: View {
    let node: ProjectFileNode
    let relativePath: String
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: node.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(FQTheme.textSecondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(FQTheme.fontSmall.weight(.medium))
                        .foregroundStyle(FQTheme.textPrimary)
                        .lineLimit(1)
                    Text(relativePath)
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                    .fill(isHovering ? FQTheme.surfaceSecondary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(relativePath)
        .accessibilityLabel("Open \(relativePath)")
        .contextMenu { ProjectFileContextMenu(url: node.url, onOpen: onOpen) }
    }
}

/// Shared right-click menu for file rows.
struct ProjectFileContextMenu: View {
    let url: URL
    var onOpen: (() -> Void)?

    var body: some View {
        if let onOpen {
            Button("Open") { onOpen() }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        Button("Copy File Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
        }
    }
}
