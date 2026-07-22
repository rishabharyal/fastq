import SwiftUI
import Foundation

// MARK: - Change model

/// A single entry from `git status --porcelain`.
struct ProjectGitChange: Identifiable, Hashable {
    /// Porcelain XY code, e.g. " M", "??", "A ", "RM".
    let status: String
    /// Repo-relative path (the *new* path for renames).
    let path: String
    /// Original path when the entry is a rename/copy, otherwise nil.
    let originalPath: String?

    init(status: String, path: String, originalPath: String? = nil) {
        self.status = status
        self.path = path
        self.originalPath = originalPath
    }

    var id: String { status + path }

    /// Single-letter badge shown in lists.
    var badge: String {
        let compact = status.trimmingCharacters(in: .whitespaces)
        if compact.hasPrefix("?") { return "U" }
        return String(compact.prefix(1))
    }

    /// True when the change is present in the index (first column non-space).
    var isStaged: Bool {
        guard let first = status.first else { return false }
        return first != " " && first != "?"
    }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    var hue: FQHue {
        switch badge {
        case "M": return .yellow
        case "A", "U": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .gray
        }
    }

    var badgeColor: Color {
        switch badge {
        case "M": return FQTheme.warning
        case "A", "U": return FQTheme.success
        case "D": return FQTheme.danger
        case "R", "C": return FQTheme.accent
        default: return FQTheme.textSecondary
        }
    }

    var describedStatus: String {
        switch badge {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "U": return "Untracked"
        default: return "Changed"
        }
    }
}

// MARK: - Git process runner

/// Thin async wrapper over `/usr/bin/git`. All work happens off the main actor.
enum GitService {
    private static let executablePath = "/usr/bin/git"

    /// Runs git and returns stdout, or nil when the process fails to launch or
    /// exits non-zero.
    static func run(_ args: [String], in dir: String) async -> String? {
        guard let result = await exec(args, in: dir), result.status == 0 else { return nil }
        return result.output
    }

    /// Runs git and returns both the exit status and stdout. Nil only when the
    /// process could not be launched at all (missing dir, missing binary).
    static func exec(_ args: [String], in dir: String) async -> (status: Int32, output: String)? {
        let arguments = args
        let directory = dir
        return await Task.detached(priority: .utility) { () -> (status: Int32, output: String)? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            var environment = ProcessInfo.processInfo.environment
            // Never let git open a pager or prompt for credentials from a GUI app.
            environment["GIT_PAGER"] = "cat"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            process.environment = environment

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
            let text = String(data: data, encoding: .utf8) ?? ""
            return (status: process.terminationStatus, output: text)
        }.value
    }

    // MARK: Queries

    /// Current branch name, or nil when not a repo / detached with no name.
    static func branch(in dir: String) async -> String? {
        guard let raw = await run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// True when `dir` sits inside a git work tree.
    static func isRepo(_ dir: String) async -> Bool {
        guard let raw = await run(["rev-parse", "--is-inside-work-tree"], in: dir) else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Parsed `git status --porcelain` entries. Empty when clean or not a repo —
    /// pair with `isRepo(_:)` when the distinction matters.
    static func status(in dir: String) async -> [ProjectGitChange] {
        guard let raw = await run(["status", "--porcelain"], in: dir) else { return [] }
        return parseStatus(raw)
    }

    /// Unified diff. `path` nil diffs the whole repo; `staged` uses `--cached`.
    /// Falls back to a `--no-index` diff so untracked files still render.
    static func diff(path: String?, staged: Bool, in dir: String) async -> String? {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--cached") }
        if let path, !path.isEmpty {
            args.append("--")
            args.append(path)
        }
        guard let text = await run(args, in: dir) else { return nil }
        if !text.isEmpty || staged { return text }

        // Nothing tracked changed — the file may be brand new (untracked).
        if let path, !path.isEmpty {
            return await untrackedDiff(path: path, in: dir) ?? text
        }
        return text
    }

    /// `git diff --no-index /dev/null <path>` — exits 1 when it produces output,
    /// which is expected, so the exit status is deliberately ignored.
    static func untrackedDiff(path: String, in dir: String) async -> String? {
        let full = URL(fileURLWithPath: dir).appendingPathComponent(path).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        let args = ["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", path]
        guard let result = await exec(args, in: dir) else { return nil }
        return result.output.isEmpty ? nil : result.output
    }

    // MARK: Porcelain parsing

    /// Parses porcelain v1 output: two status columns, a space, then the path.
    /// Handles `old -> new` renames and C-quoted paths.
    static func parseStatus(_ raw: String) -> [ProjectGitChange] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> ProjectGitChange? in
            let text = String(line)
            guard text.count > 3 else { return nil }
            let statusCode = String(text.prefix(2))
            var payload = String(text.dropFirst(3))

            var original: String?
            // Renames/copies arrive as "old -> new"; show the new path.
            if let arrow = payload.range(of: " -> ") {
                original = unquote(String(payload[payload.startIndex..<arrow.lowerBound]))
                payload = String(payload[arrow.upperBound...])
            }
            let path = unquote(payload)
            guard !path.isEmpty else { return nil }
            return ProjectGitChange(status: statusCode, path: path, originalPath: original)
        }
    }

    /// Git quotes paths containing spaces/unicode with C-style escapes.
    static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        text = String(text.dropFirst().dropLast())

        var out = ""
        var iterator = text.makeIterator()
        var pendingBytes: [UInt8] = []

        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            out += String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll()
        }

        while let character = iterator.next() {
            guard character == "\\" else {
                flushBytes()
                out.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                flushBytes()
                out.append("\\")
                break
            }
            switch escaped {
            case "n": flushBytes(); out.append("\n")
            case "t": flushBytes(); out.append("\t")
            case "r": flushBytes(); out.append("\r")
            case "\"": flushBytes(); out.append("\"")
            case "\\": flushBytes(); out.append("\\")
            case "0", "1", "2", "3", "4", "5", "6", "7":
                // \NNN octal byte — collect the run so UTF-8 sequences survive.
                var digits = String(escaped)
                for _ in 0..<2 {
                    guard let next = iterator.next() else { break }
                    if next.isNumber, let value = next.wholeNumberValue, value < 8 {
                        digits.append(next)
                    } else {
                        // Not octal: emit what we have, then handle the char plainly.
                        if let byte = UInt8(digits, radix: 8) { pendingBytes.append(byte) }
                        flushBytes()
                        out.append(next)
                        digits = ""
                        break
                    }
                }
                if !digits.isEmpty, let byte = UInt8(digits, radix: 8) {
                    pendingBytes.append(byte)
                }
            default:
                flushBytes()
                out.append(escaped)
            }
        }
        flushBytes()
        return out
    }
}
