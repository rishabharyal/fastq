import SwiftUI
import AppKit

// MARK: - Model

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct GitChange: Identifiable, Hashable {
    let status: String // porcelain XY, e.g. " M", "??", "A "
    let path: String   // repo-relative
    var id: String { status + path }

    var badge: String {
        let compact = status.trimmingCharacters(in: .whitespaces)
        if compact.hasPrefix("?") { return "U" }
        return String(compact.prefix(1))
    }

    var badgeColor: Color {
        switch badge {
        case "M": return Color(red: 0.95, green: 0.72, blue: 0.25)
        case "A", "U": return Color(red: 0.42, green: 0.80, blue: 0.46)
        case "D": return Color(red: 0.95, green: 0.42, blue: 0.40)
        case "R", "C": return Color(red: 0.45, green: 0.65, blue: 1.0)
        default: return .gray
        }
    }
}

/// Backs the sidebar file browser: lazy directory tree, filename search, and
/// git status for the active session's project.
@MainActor
final class FileBrowserModel: ObservableObject {
    @Published private(set) var rootPath: String?
    @Published var expanded: Set<String> = []
    @Published private(set) var children: [String: [FileNode]] = [:]
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var searchResults: [FileNode] = []
    @Published private(set) var gitChanges: [GitChange] = []
    @Published private(set) var gitBranch: String?
    @Published private(set) var isGitRepo = false

    private var searchTask: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?

    /// Directories that are never worth walking.
    nonisolated static let skippedNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".venv", "venv",
        "__pycache__", ".next", "dist", "build.noindex",
    ]

    func setRoot(_ path: String?) {
        guard path != rootPath else { return }
        rootPath = path
        expanded = []
        children = [:]
        searchText = ""
        searchResults = []
        gitChanges = []
        gitBranch = nil
        isGitRepo = false
        if let path {
            loadChildren(of: path)
            refreshGit()
        }
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
            .compactMap { itemURL -> FileNode? in
                let name = itemURL.lastPathComponent
                if name == ".git" { return nil }
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return FileNode(url: itemURL, isDirectory: isDir)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        children[path] = nodes
    }

    func toggle(_ node: FileNode) {
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

    func refreshTree() {
        guard let rootPath else { return }
        loadChildren(of: rootPath)
        for path in expanded {
            loadChildren(of: path)
        }
    }

    /// Flattened visible rows (node + indent depth) for the tree list.
    var visibleRows: [(node: FileNode, depth: Int)] {
        guard let rootPath else { return [] }
        var rows: [(FileNode, Int)] = []
        func walk(_ path: String, depth: Int) {
            for node in children[path] ?? [] {
                rows.append((node, depth))
                if node.isDirectory, expanded.contains(node.id) {
                    walk(node.id, depth: depth + 1)
                }
            }
        }
        walk(rootPath, depth: 0)
        return rows.map { (node: $0.0, depth: $0.1) }
    }

    // MARK: Search (go to file)

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let rootPath else {
            searchResults = []
            return
        }
        searchTask = Task { [rootPath] in
            try? await Task.sleep(nanoseconds: 180_000_000) // debounce typing
            guard !Task.isCancelled else { return }
            let results = await Self.findFiles(matching: query, under: rootPath)
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    private nonisolated static func findFiles(matching query: String, under root: String) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            findFilesSync(matching: query, under: root)
        }.value
    }

    private nonisolated static func findFilesSync(matching query: String, under root: String) -> [FileNode] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var matches: [FileNode] = []
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
                matches.append(FileNode(url: url, isDirectory: false))
            }
        }
        // Prefix matches first, then shorter names — cheap "go to file" ranking.
        return matches.sorted { a, b in
            let ap = a.name.lowercased().hasPrefix(lowered)
            let bp = b.name.lowercased().hasPrefix(lowered)
            if ap != bp { return ap }
            return a.name.count < b.name.count
        }
    }

    // MARK: Git

    func refreshGit() {
        guard let rootPath else { return }
        gitTask?.cancel()
        gitTask = Task { [rootPath] in
            let branch = await Self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: rootPath)
            let status = await Self.runGit(["status", "--porcelain"], in: rootPath)
            guard !Task.isCancelled, self.rootPath == rootPath else { return }
            guard let status else {
                isGitRepo = false
                gitChanges = []
                gitBranch = nil
                return
            }
            isGitRepo = true
            gitBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
            gitChanges = status.split(separator: "\n").compactMap { line -> GitChange? in
                guard line.count > 3 else { return nil }
                let raw = String(line)
                let statusCode = String(raw.prefix(2))
                var path = String(raw.dropFirst(3))
                // Renames arrive as "old -> new"; show the new path.
                if let arrow = path.range(of: " -> ") {
                    path = String(path[arrow.upperBound...])
                }
                if path.hasPrefix("\""), path.hasSuffix("\"") {
                    path = String(path.dropFirst().dropLast())
                }
                return GitChange(status: statusCode, path: path)
            }
        }
    }

    private nonisolated static func runGit(_ arguments: [String], in directory: String) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }
}

// MARK: - View

enum ExplorerSection: String, CaseIterable, Identifiable {
    case files
    case git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .git: return "Source Control"
        }
    }

    var systemImage: String {
        switch self {
        case .files: return "folder"
        case .git: return "arrow.triangle.branch"
        }
    }
}

/// Right explorer panel: file tree or git changes for the active project.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel
    let projectName: String?
    var section: ExplorerSection = .files
    var onOpenFile: ((URL) -> Void)?

    private func openFile(_ url: URL) {
        if let onOpenFile {
            onOpenFile(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.rootPath == nil {
                emptyState
            } else {
                header
                if section == .files {
                    searchField
                    if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchList
                    } else {
                        fileTree
                    }
                } else {
                    gitHeader
                    gitList
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: section) { _, value in
            if value == .git { model.refreshGit() }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No project yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Launch an agent from Fastq and its project files show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: section == .files ? "folder.fill" : "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.35, green: 0.62, blue: 1.0))
            Text(section == .files ? (projectName ?? "Project") : section.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                model.refreshTree()
                model.refreshGit()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var gitHeader: some View {
        HStack(spacing: 6) {
            if let branch = model.gitBranch {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                Text(branch)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            } else if model.isGitRepo {
                Text("Git")
                    .font(.system(size: 11, weight: .medium))
            }
            Spacer(minLength: 0)
            if !model.gitChanges.isEmpty {
                Text("\(model.gitChanges.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            TextField("Go to file…", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Tree

    private var fileTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.visibleRows, id: \.node.id) { row in
                    FileRow(
                        node: row.node,
                        depth: row.depth,
                        isExpanded: model.expanded.contains(row.node.id),
                        onTap: {
                            if row.node.isDirectory {
                                model.toggle(row.node)
                            } else {
                                openFile(row.node.url)
                            }
                        },
                        onOpen: { openFile(row.node.url) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }

    // MARK: Search results

    private var searchList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.searchResults.isEmpty {
                    Text("No matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                } else {
                    ForEach(model.searchResults) { node in
                        SearchResultRow(node: node, root: model.rootPath ?? "") {
                            openFile(node.url)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }

    // MARK: Git list

    private var gitList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !model.isGitRepo {
                    Text("Not a git repository")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                } else if model.gitChanges.isEmpty {
                    Text("Working tree clean")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                } else {
                    ForEach(model.gitChanges) { change in
                        GitChangeRow(change: change, root: model.rootPath ?? "") {
                            openFile(URL(fileURLWithPath: model.rootPath ?? "").appendingPathComponent(change.path))
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .task(id: model.rootPath) {
            // Keep git status fresh while the pane is visible.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                model.refreshGit()
            }
        }
    }
}

// MARK: - Rows

private struct FileRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                    .font(.system(size: 9.5))
                    .foregroundStyle(node.isDirectory
                                     ? Color(red: 0.45, green: 0.65, blue: 1.0).opacity(0.8)
                                     : .white.opacity(0.42))
                    .frame(width: 13)
                Text(node.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 13 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !node.isDirectory { onOpen() }
        })
        .contextMenu { FileContextMenu(url: node.url, onOpen: onOpen) }
    }
}

private struct SearchResultRow: View {
    let node: FileNode
    let root: String
    let onOpen: () -> Void
    @State private var isHovering = false

    private var relativePath: String {
        let path = node.url.path
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text(relativePath)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(relativePath)")
        .contextMenu { FileContextMenu(url: node.url, onOpen: onOpen) }
    }
}

private struct GitChangeRow: View {
    let change: GitChange
    let root: String
    let onOpen: () -> Void
    @State private var isHovering = false

    private var fileURL: URL {
        URL(fileURLWithPath: root).appendingPathComponent(change.path)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                Text(change.badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.badgeColor)
                    .frame(width: 12)
                Text((change.path as NSString).lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text((change.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(change.path)
        .contextMenu { FileContextMenu(url: fileURL, onOpen: onOpen) }
    }
}

private struct FileContextMenu: View {
    let url: URL
    var onOpen: (() -> Void)?

    var body: some View {
        Button("Open") {
            if let onOpen {
                onOpen()
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}

