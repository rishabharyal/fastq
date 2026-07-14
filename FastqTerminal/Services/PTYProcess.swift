import Foundation
import Darwin

/// Minimal PTY host. GhosttyKit will replace the *view* later; session process model stays.
final class PTYProcess {
    private(set) var masterFD: Int32 = -1
    private(set) var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { childPID > 0 }

    func start(command: String, arguments: [String], workingDirectory: String, environment: [String: String] = [:]) throws {
        var master: Int32 = -1
        let pid = fastq_forkpty(&master, 40, 120)
        if pid < 0 {
            throw PTYError.openFailed(errno)
        }

        if pid == 0 {
            // Child
            _ = workingDirectory.withCString { chdir($0) }

            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            env["TERM"] = env["TERM"] ?? "xterm-256color"
            env["COLORTERM"] = env["COLORTERM"] ?? "truecolor"

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
        _ = fastq_resize_pty(masterFD, Int32(rows), Int32(cols))
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
                let data = Data(buffer.prefix(count))
                DispatchQueue.main.async {
                    self?.onOutput?(data)
                }
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

enum PTYError: LocalizedError {
    case openFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code): return "forkpty failed (\(code))"
        }
    }
}
