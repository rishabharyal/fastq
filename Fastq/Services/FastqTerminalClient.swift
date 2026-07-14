import Foundation
import Darwin
import AppKit

/// Client used by the Fastq launcher to talk to Fastq Terminal.
/// The launcher starts Fastq Terminal automatically — you never open it by hand.
@MainActor
final class FastqTerminalClient {
    static let shared = FastqTerminalClient()

    private let bundleID = "app.fastq.terminal"

    /// True when Fastq Terminal is running and its IPC socket answers.
    func isTerminalAlive() -> Bool {
        isTerminalProcessRunning() && isReachable()
    }

    /// True when the Terminal app process exists (even if the window is hidden).
    func isTerminalProcessRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func ensureTerminalRunning() async throws {
        if isReachable() { return }

        if isTerminalProcessRunning() {
            // App is up but socket not ready yet — wait briefly.
            if await waitForSocket(attempts: 30) { return }
        }

        guard let appURL = locateTerminalApp() else {
            throw TerminalClientError.notInstalled
        }

        let config = NSWorkspace.OpenConfiguration()
        // Don't force activation here — createSession/focusSession call showMainWindow.
        // Activating during openApplication + WindowGroup was spawning a second window.
        config.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            throw TerminalClientError.launchFailed(error.localizedDescription)
        }

        guard await waitForSocket(attempts: 50) else {
            throw TerminalClientError.timeout
        }
    }

    func createSession(_ request: CreateSessionRequest) async throws -> SessionInfo {
        try await ensureTerminalRunning()
        let response = try await send(.createSession(request))
        switch response {
        case .sessionCreated(let info):
            revealTerminalApp()
            return info
        case .error(let message):
            throw TerminalClientError.server(message)
        default:
            throw TerminalClientError.unexpectedResponse
        }
    }

    func focusSession(_ id: UUID) async throws {
        try await ensureTerminalRunning()
        _ = try await send(.focusSession(sessionID: id))
        revealTerminalApp()
    }

    /// Launcher ⌘T: open/reveal the terminal window. Starts the app if
    /// needed; with no live sessions the window would stay hidden, so open a
    /// plain shell tab in that case (createSession shows the window).
    func showTerminal() async throws {
        try await ensureTerminalRunning()
        if try await listSessions().isEmpty {
            let home = NSHomeDirectory()
            _ = try await createSession(CreateSessionRequest(
                title: "Terminal",
                projectName: "Home",
                projectPath: home,
                command: "",
                prompt: "",
                tool: "shell"
            ))
        } else {
            revealTerminalApp()
        }
    }

    /// Bring Fastq Terminal forward (restores a window hidden via the red close button).
    private func revealTerminalApp() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        for app in apps {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        // Activate can race ahead of IPC showMainWindow — nudge again shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID) {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
    }

    /// Switch the Terminal tab without activating that app (keeps launcher key).
    func selectSession(_ id: UUID) async throws {
        guard isSocketAlive() else { return }
        _ = try await send(.selectSession(sessionID: id))
    }

    func cycleSession(delta: Int) async throws {
        guard isSocketAlive() else { return }
        _ = try await send(.cycleSession(delta: delta))
    }

    func quitSession(_ id: UUID) async throws {
        guard isSocketAlive() else { return }
        _ = try await send(.quitSession(sessionID: id))
    }

    func listSessions() async throws -> [SessionInfo] {
        guard isSocketAlive() else { return [] }
        let response = try await send(.listSessions)
        switch response {
        case .sessionList(let list):
            return list
        case .error(let message):
            throw TerminalClientError.server(message)
        default:
            throw TerminalClientError.unexpectedResponse
        }
    }

    func sendText(_ id: UUID, text: String) async throws {
        try await ensureTerminalRunning()
        _ = try await send(.sendText(sessionID: id, text: text))
    }

    // MARK: - Discovery / launch

    private func isSocketAlive() -> Bool {
        FileManager.default.fileExists(atPath: FastqIPC.socketPath)
    }

    private func isReachable() -> Bool {
        guard isSocketAlive() else { return false }
        return (try? sendSyncPing()) == true
    }

    private func waitForSocket(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if isReachable() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Find Fastq Terminal.app next to the launcher, in /Applications, or in Xcode DerivedData.
    private func locateTerminalApp() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        // Sibling of the running Fastq.app (Release / same Products folder)
        candidates.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Fastq Terminal.app")
        )
        candidates.append(URL(fileURLWithPath: "/Applications/Fastq Terminal.app"))

        // Xcode DerivedData (common while developing)
        let derived = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: derived,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == "Fastq Terminal.app",
                   url.path.contains("/Build/Products/") {
                    candidates.append(url)
                    // Don't walk inside .app bundles
                    enumerator.skipDescendants()
                }
            }
        }

        // Also check this repo's local derived data folders used by our scripts
        let repoDerived = [
            Bundle.main.bundleURL
                .deletingLastPathComponent() // Products/Debug
                .deletingLastPathComponent() // Products
                .deletingLastPathComponent() // Build
                .deletingLastPathComponent() // ...
        ]
        _ = repoDerived

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return url
        }

        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func sendSyncPing() -> Bool {
        (try? Self.sendSync(.ping)) != nil
    }

    // MARK: - Transport

    private func send(_ message: FastqIPCMessage) async throws -> FastqIPCMessage {
        try await Task.detached(priority: .userInitiated) {
            try Self.sendSync(message)
        }.value
    }

    nonisolated private static func sendSync(_ message: FastqIPCMessage) throws -> FastqIPCMessage {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TerminalClientError.timeout }

        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = FastqIPC.socketPath
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { cstr in
                _ = strncpy(ptr, cstr, 104)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw TerminalClientError.timeout
        }

        let payload = try FastqIPCFraming.encode(message)
        let written = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return Darwin.write(fd, base, payload.count)
        }
        guard written == payload.count else {
            throw TerminalClientError.unexpectedResponse
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
                if let response = try FastqIPCFraming.decode(from: &buffer) {
                    return response
                }
            } else if count == 0 {
                break
            } else if errno != EAGAIN && errno != EINTR {
                break
            }
            usleep(10_000)
        }
        throw TerminalClientError.timeout
    }
}

enum TerminalClientError: LocalizedError {
    case timeout
    case unexpectedResponse
    case server(String)
    case notInstalled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Timed out waiting for Fastq Terminal to start."
        case .unexpectedResponse:
            return "Unexpected response from Fastq Terminal."
        case .server(let message):
            return message
        case .notInstalled:
            return "Fastq Terminal isn’t built yet. In Xcode, build the FastqTerminal scheme once (⌘B), then try again — Fastq will launch it automatically."
        case .launchFailed(let message):
            return "Couldn’t start Fastq Terminal: \(message)"
        }
    }
}
