import Foundation
import Darwin

/// Minimal PTY host. Ghostty renders the bytes; this owns the process + fd.
/// `write` is called from Ghostty IO threads — it only touches the master fd,
/// which is safe, hence the unchecked Sendable conformance below.
final class PTYProcess {
    private(set) var masterFD: Int32 = -1
    private(set) var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var currentCols: UInt16 = 120
    private var currentRows: UInt16 = 40
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { childPID > 0 }

    var size: (cols: UInt16, rows: UInt16) { (currentCols, currentRows) }

    func start(
        command: String,
        arguments: [String],
        workingDirectory: String,
        cols: UInt16,
        rows: UInt16,
        environment: [String: String] = [:]
    ) throws {
        // Restart-safe: a session can fork a fallback shell onto the same
        // instance after its first child exits.
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }

        currentCols = max(cols, 20)
        currentRows = max(rows, 10)

        var master: Int32 = -1
        let pid = fastq_forkpty(&master, Int32(currentRows), Int32(currentCols))
        if pid < 0 {
            throw PTYError.openFailed(errno)
        }

        if pid == 0 {
            // Child
            _ = workingDirectory.withCString { chdir($0) }

            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            // Interactive TUI agents (Cursor / Claude / Codex / Grok / OpenCode)
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            env["FORCE_COLOR"] = "1"
            env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
            env["LC_ALL"] = env["LC_ALL"] ?? env["LANG"] ?? "en_US.UTF-8"
            // Never export COLUMNS/LINES: ncurses prefers them over the
            // TIOCGWINSZ ioctl, so a stale value pins TUIs to the birth size
            // and they ignore later window resizes.
            env.removeValue(forKey: "COLUMNS")
            env.removeValue(forKey: "LINES")
            // Prevent non-interactive / CI modes that break TUIs.
            env.removeValue(forKey: "CI")
            env.removeValue(forKey: "GITHUB_ACTIONS")

            let envPointers = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
            let argv = ([command] + arguments).map { strdup($0) } + [nil]
            execve(command, argv, envPointers)
            _exit(127)
        }

        masterFD = master
        childPID = pid
        startReading()
        watchExit()
    }

    func write(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = Darwin.write(masterFD, base, data.count)
        }
    }

    func write(_ string: String) {
        write(Data(string.utf8))
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        let nextCols = max(cols, 1)
        let nextRows = max(rows, 1)
        if nextCols == currentCols, nextRows == currentRows { return }
        currentCols = nextCols
        currentRows = nextRows
        _ = fastq_resize_pty(masterFD, Int32(nextRows), Int32(nextCols))
    }

    func terminate() {
        readSource?.cancel()
        readSource = nil
        if childPID > 0 {
            kill(childPID, SIGTERM)
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    private func startReading() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                // Deliver on the read queue — the emulator parses on its own
                // serial queue. Bouncing through main floods it during heavy
                // TUI redraws and delays keystroke echo (typing feels laggy).
                self?.onOutput?(Data(buffer.prefix(count)))
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        readSource = source
        source.resume()
    }

    private func watchExit() {
        let pid = childPID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            DispatchQueue.main.async {
                self?.onExit?(status)
                self?.childPID = 0
            }
        }
    }

    deinit {
        terminate()
    }
}

extension PTYProcess: @unchecked Sendable {}

enum PTYError: LocalizedError {
    case openFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code): return "forkpty failed (\(code))"
        }
    }
}
