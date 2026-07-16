import Foundation
import Combine

struct FileMentionItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let relativePath: String
    let path: String
    let projectName: String
    let isDirectory: Bool
}

/// High-performance @-file index + fuzzy finder.
///
/// Indexing prefers `git ls-files` (respects .gitignore, fully recursive, very fast),
/// then `fd`, then a bounded filesystem walk. All search/scoring runs off the main
/// actor so typing never stalls the launcher UI.
@MainActor
final class FileMentionIndex: ObservableObject {
    @Published private(set) var results: [FileMentionItem] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0

    private let engine = FileMentionEngine()
    private var indexedRoots: [String] = []
    private var searchGeneration = 0
    private var indexGeneration = 0
    private var searchTask: Task<Void, Never>?

    func ensureIndexed(projects: [ProjectFolder], primaryPath: String?) {
        ensureIndexed(namedRoots: projects.map { ($0.name, $0.path) }, primaryPath: primaryPath)
    }

    func ensureIndexed(namedRoots: [(name: String, path: String)], primaryPath: String?) {
        let roots = namedRoots.map(\.path).sorted()
        guard roots != indexedRoots || indexedCount == 0 else { return }

        indexGeneration += 1
        let gen = indexGeneration
        indexedRoots = roots
        isIndexing = true

        let snapshot = namedRoots
        Task(priority: .utility) {
            await engine.reindex(projects: snapshot)
            let count = await engine.count
            await MainActor.run {
                guard gen == self.indexGeneration else { return }
                self.indexedCount = count
                self.isIndexing = false
            }
        }
    }

    /// Debounced fuzzy search — never blocks the main thread for scoring.
    func query(_ raw: String, primaryPath: String?, limit: Int = 40) {
        searchGeneration += 1
        let gen = searchGeneration
        let q = raw
        searchTask?.cancel()
        searchTask = Task(priority: .userInitiated) { [engine] in
            // ~1 frame debounce — coalesces rapid keystrokes.
            try? await Task.sleep(nanoseconds: 28_000_000)
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            let hits = await engine.search(query: q, primaryPath: primaryPath, limit: limit)
            guard !Task.isCancelled, gen == self.searchGeneration else { return }

            await MainActor.run {
                guard gen == self.searchGeneration else { return }
                self.results = hits
            }
        }
    }

    func clearResults() {
        searchTask?.cancel()
        searchGeneration += 1
        results = []
    }
}

// MARK: - Background engine

actor FileMentionEngine {
    private var items: [FileMentionItem] = []
    /// Lowercased haystacks kept alongside items for zero-alloc rescoring.
    private var haystacks: [String] = []

    var count: Int { items.count }

    func reindex(projects: [(name: String, path: String)]) {
        var collected: [FileMentionItem] = []
        collected.reserveCapacity(8_192)

        for project in projects {
            collected.append(contentsOf: Self.listFiles(root: project.path, projectName: project.name))
        }

        // Stable order: primary-ish by path length then name.
        collected.sort { a, b in
            if a.relativePath.count != b.relativePath.count {
                return a.relativePath.count < b.relativePath.count
            }
            return a.relativePath < b.relativePath
        }

        items = collected
        // Include the project name so `@subsets_api/mod`-style queries match —
        // the same `project/relative/path` shape mentions are inserted as.
        haystacks = collected.map { ($0.projectName + "/" + $0.relativePath + " " + $0.name).lowercased() }
    }

    func search(query: String, primaryPath: String?, limit: Int) -> [FileMentionItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            // Empty query: prefer primary project, then shallow paths.
            var ranked = items
            if let primary = primaryPath {
                ranked.sort { a, b in
                    let ap = a.path.hasPrefix(primary)
                    let bp = b.path.hasPrefix(primary)
                    if ap != bp { return ap && !bp }
                    return a.relativePath.count < b.relativePath.count
                }
            }
            return Array(ranked.prefix(limit))
        }

        let pattern = Array(q.lowercased().utf8)
        var scored: [(Int, Int)] = [] // (score, index)
        scored.reserveCapacity(min(items.count, 2_048))

        for i in items.indices {
            if let score = FuzzyPath.score(pattern: pattern, in: haystacks[i]) {
                var s = score
                if let primary = primaryPath, items[i].path.hasPrefix(primary) {
                    s += 25 // prefer active project
                }
                // Prefer basename hits.
                if FuzzyPath.score(pattern: pattern, in: items[i].name.lowercased()) != nil {
                    s += 15
                }
                scored.append((s, i))
            }
        }

        scored.sort { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return items[a.1].relativePath.count < items[b.1].relativePath.count
        }

        return scored.prefix(limit).map { items[$0.1] }
    }

    // MARK: Listing

    private static let skippedDirectories: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".next", "dist", "build", "DerivedData",
        ".build", "Pods", ".turbo", ".cache", "coverage",
        "vendor", "__pycache__", ".venv", "venv", "target",
        ".gradle", ".idea", ".tox", "Carthage", ".yarn",
        "xcuserdata", "*.xcworkspace"
    ]

    private static let maxFilesPerRoot = 50_000

    private static func listFiles(root: String, projectName: String) -> [FileMentionItem] {
        if let git = gitList(root: root, projectName: projectName), !git.isEmpty {
            return git
        }
        if let fd = fdList(root: root, projectName: projectName), !fd.isEmpty {
            return fd
        }
        return walkList(root: root, projectName: projectName)
    }

    /// Fast path: git index + untracked (respects .gitignore). Fully recursive.
    private static func gitList(root: String, projectName: String) -> [FileMentionItem]? {
        // `.git` may be a directory or a worktree/gitfile.
        let gitPath = (root as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitPath) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = [
            "-C", root,
            "ls-files", "-z",
            "--cached", "--others", "--exclude-standard"
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }
        // Drain the pipe BEFORE waiting: output larger than the ~64KB pipe
        // buffer would otherwise deadlock (git blocks writing, we block on
        // exit) and the spinner never stops.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        guard !data.isEmpty else { return [] }

        var results: [FileMentionItem] = []
        results.reserveCapacity(1_024)
        data.split(separator: 0).forEach { chunk in
            guard results.count < maxFilesPerRoot else { return }
            guard let rel = String(data: Data(chunk), encoding: .utf8), !rel.isEmpty else { return }
            if rel.hasSuffix("/") { return }
            let name = (rel as NSString).lastPathComponent
            let full = (root as NSString).appendingPathComponent(rel)
            results.append(
                FileMentionItem(
                    name: name,
                    relativePath: rel,
                    path: full,
                    projectName: projectName,
                    isDirectory: false
                )
            )
        }
        return results
    }

    /// Second path: `fd` if installed (`brew install fd`).
    private static func fdList(root: String, projectName: String) -> [FileMentionItem]? {
        let candidates = [
            "/opt/homebrew/bin/fd",
            "/usr/local/bin/fd",
            "\(NSHomeDirectory())/.local/bin/fd"
        ]
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = [
            "--type", "f",
            "--hidden",
            "--exclude", ".git",
            "--exclude", "node_modules",
            "--exclude", "DerivedData",
            "--exclude", ".build",
            "--print0",
            ".",
            root
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }
        // Same pipe-drain-before-wait as gitList — see comment there.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        var results: [FileMentionItem] = []
        results.reserveCapacity(1_024)
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        data.split(separator: 0).forEach { chunk in
            guard results.count < maxFilesPerRoot else { return }
            guard let full = String(data: Data(chunk), encoding: .utf8), !full.isEmpty else { return }
            let relative: String
            if full.hasPrefix(rootPrefix) {
                relative = String(full.dropFirst(rootPrefix.count))
            } else if full.hasPrefix(root + "/") {
                relative = String(full.dropFirst(root.count + 1))
            } else {
                relative = (full as NSString).lastPathComponent
            }
            results.append(
                FileMentionItem(
                    name: (full as NSString).lastPathComponent,
                    relativePath: relative,
                    path: full,
                    projectName: projectName,
                    isDirectory: false
                )
            )
        }
        return results
    }

    private static func walkList(root: String, projectName: String) -> [FileMentionItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [FileMentionItem] = []
        results.reserveCapacity(1_024)
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        while let url = enumerator.nextObject() as? URL {
            if results.count >= maxFilesPerRoot { break }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let full = url.path
            let relative: String
            if full.hasPrefix(rootPrefix) {
                relative = String(full.dropFirst(rootPrefix.count))
            } else {
                relative = url.lastPathComponent
            }

            results.append(
                FileMentionItem(
                    name: url.lastPathComponent,
                    relativePath: relative,
                    path: full,
                    projectName: projectName,
                    isDirectory: false
                )
            )
        }
        return results
    }
}

// MARK: - fzf / nucleo-style fuzzy scorer (subsequence + bonuses)

/// Pure-Swift fuzzy path scorer inspired by fzf/nucleo.
/// Hot path operates on UTF-8 bytes — suitable for tens of thousands of paths per keystroke.
enum FuzzyPath {
    /// Returns a score, or `nil` if `pattern` is not a subsequence of `haystack`.
    static func score(pattern: [UInt8], in haystack: String) -> Int? {
        if pattern.isEmpty { return 0 }
        let bytes = Array(haystack.utf8)
        return score(pattern: pattern, haystack: bytes)
    }

    static func score(pattern: [UInt8], haystack: [UInt8]) -> Int? {
        guard !pattern.isEmpty else { return 0 }
        guard pattern.count <= haystack.count else { return nil }

        var score = 0
        var pi = 0
        var consecutive = 0
        var firstIndex = -1
        var lastIndex = -1

        for hi in haystack.indices {
            let hc = haystack[hi]
            let pc = pattern[pi]
            if hc == pc {
                if firstIndex < 0 { firstIndex = hi }
                lastIndex = hi

                var bonus = 0
                if hi == 0 {
                    bonus = 12
                } else {
                    let prev = haystack[hi - 1]
                    if prev == UInt8(ascii: "/") || prev == UInt8(ascii: ".")
                        || prev == UInt8(ascii: "_") || prev == UInt8(ascii: "-")
                        || prev == UInt8(ascii: " ") {
                        bonus = 10
                    } else if prev >= UInt8(ascii: "a"), prev <= UInt8(ascii: "z"),
                              hc >= UInt8(ascii: "A"), hc <= UInt8(ascii: "Z") {
                        // camelCase boundary
                        bonus = 8
                    }
                }

                if consecutive > 0 {
                    bonus += 4 + consecutive // reward runs
                }

                score += 16 + bonus
                consecutive += 1
                pi += 1
                if pi == pattern.count { break }
            } else {
                consecutive = 0
            }
        }

        guard pi == pattern.count else { return nil }

        // Compact matches beat spread-out ones.
        if firstIndex >= 0, lastIndex >= firstIndex {
            let span = lastIndex - firstIndex + 1
            score -= max(0, span - pattern.count) * 2
        }
        // Prefer shorter paths overall.
        score -= min(haystack.count, 80) / 4
        return score
    }
}
