import Foundation

/// Spawns a headless CLI (claude / cursor-agent), streams its stdout
/// line-by-line to the caller, and reports exit with the stderr tail.
final class HeadlessProcessRunner {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    /// True when the process reads user messages from stdin (Claude's
    /// persistent --input-format stream-json mode).
    private(set) var usesStdin = false
    private var stdoutBuffer = Data()
    private var stderrTail = Data()
    private let queue = DispatchQueue(label: "fastq.headless.runner")

    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    var isRunning: Bool { process.isRunning }
    var pid: pid_t? { process.isRunning ? process.processIdentifier : nil }

    func start(executable: String, arguments: [String], currentDirectory: String, interactive: Bool = false) throws {
        usesStdin = interactive
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        let path = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extra + [path]).joined(separator: ":")
        // Never inherit an interactive TERM — the CLIs must stay in print mode.
        env["TERM"] = "dumb"
        process.environment = env

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = interactive ? stdinPipe : FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async {
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                self.stdoutBuffer.append(data)
                self.drainLines()
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async {
                self.stderrTail.append(data)
                // Keep only the last 8 KB for error reporting.
                if self.stderrTail.count > 8192 {
                    self.stderrTail = self.stderrTail.suffix(8192)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                // Flush whatever is still buffered.
                if let rest = try? self.stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    self.stdoutBuffer.append(rest)
                }
                self.drainLines(flushRemainder: true)
                let tail = String(data: self.stderrTail, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status = proc.terminationStatus
                DispatchQueue.main.async {
                    self.onExit?(status, tail)
                }
            }
        }

        try process.run()
    }

    /// Writes one newline-terminated JSON line to the CLI's stdin
    /// (stream-json input mode). Returns false when the pipe is unusable.
    @discardableResult
    func send(line: String) -> Bool {
        guard usesStdin, process.isRunning,
              let data = (line + "\n").data(using: .utf8) else { return false }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Graceful end for a persistent session: stdin EOF lets the CLI finish
    /// and exit on its own.
    func closeInput() {
        guard usesStdin else { return }
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// Documented graceful stop: Claude Code aborts the turn, kills child
    /// process trees, runs SessionEnd hooks, exits 143.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
    }

    private func drainLines(flushRemainder: Bool = false) {
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            emit(lineData)
        }
        if flushRemainder, !stdoutBuffer.isEmpty {
            let rest = stdoutBuffer
            stdoutBuffer = Data()
            emit(rest)
        }
    }

    private func emit(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onLine?(line)
        }
    }
}

/// Shared executable resolution for headless engines.
enum HeadlessToolResolver {
    @MainActor
    static func resolve(_ tool: AgentToolKind, settings: AppSettings?) -> String? {
        // Respect a user-configured absolute path first.
        if let configured = settings?.tools.first(where: { $0.kind == tool })?.commandPath,
           configured.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        if let detected = ToolPathDetector.resolve(tool.defaultCommand) {
            return detected
        }
        for candidate in tool.searchPaths where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(tool.defaultCommand)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
