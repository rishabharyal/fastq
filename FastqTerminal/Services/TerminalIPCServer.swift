import Foundation
import Darwin
import AppKit

@MainActor
final class TerminalIPCServer {
    private let store: TerminalSessionStore
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Client] = []

    init(store: TerminalSessionStore) {
        self.store = store
    }

    func start() {
        try? FileManager.default.createDirectory(
            atPath: FastqIPC.supportDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: FastqIPC.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("IPC socket() failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = FastqIPC.socketPath
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { cstr in
                _ = strncpy(ptr, cstr, 104)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("IPC bind failed: \(errno)")
            Darwin.close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            print("IPC listen failed")
            Darwin.close(fd)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        acceptSource = source
        source.resume()
        print("FastqTerminal IPC listening on \(FastqIPC.socketPath)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        clients.forEach { $0.shutdown() }
        clients.removeAll()
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: FastqIPC.socketPath)
    }

    private func acceptClient() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        let client = Client(fd: clientFD) { [weak self] message in
            self?.handle(message) ?? .error("Server unavailable")
        } onClose: { [weak self] client in
            self?.clients.removeAll { $0 === client }
        }
        clients.append(client)
        client.start()
    }

    private func handle(_ message: FastqIPCMessage) -> FastqIPCMessage {
        switch message {
        case .ping:
            return .ok
        case .listSessions:
            return .sessionList(store.infos())
        case .createSession(let request):
            do {
                let session = try store.create(from: request)
                // Mount Ghostty hosts for the PTY, but keep the window hidden —
                // the launcher preview is the interactive surface.
                (NSApp.delegate as? TerminalAppDelegate)?.ensureMainWindowMounted()
                return .sessionCreated(session.info)
            } catch {
                return .error(error.localizedDescription)
            }
        case .focusSession(let id):
            store.focus(id)
            // Don't steal focus from the launcher — select only.
            return .ok
        case .selectSession(let id):
            store.select(id)
            return .ok
        case .quitSession(let id):
            store.quit(id)
            if store.sessions.isEmpty {
                (NSApp.delegate as? TerminalAppDelegate)?.hideMainWindow()
            }
            return .ok
        case .sendText(let id, let text):
            store.sendText(id, text: text)
            return .ok
        case .sendInput(let id, let data):
            store.sendInput(id, data: data)
            return .ok
        case .cycleSession(let delta):
            _ = store.cycle(by: delta)
            return .ok
        case .mirrorAttach(let id):
            guard let info = store.mirrorAttach(id) else {
                return .error("Session not found")
            }
            return .mirrorAttached(info)
        case .mirrorPoll(let id, let cursor):
            guard let chunk = store.mirrorChunk(id, since: cursor) else {
                return .error("Session not found")
            }
            return .mirrorChunk(chunk)
        case .mirrorDetach:
            return .ok
        case .sessionCreated, .sessionList, .mirrorAttached, .mirrorChunk, .ok, .error:
            return .error("Unexpected client→server payload")
        }
    }
}

private final class Client {
    private let fd: Int32
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private let handler: (FastqIPCMessage) -> FastqIPCMessage
    private let onClose: (Client) -> Void

    init(fd: Int32, handler: @escaping (FastqIPCMessage) -> FastqIPCMessage, onClose: @escaping (Client) -> Void) {
        self.fd = fd
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        self.source = source
        source.resume()
    }

    func shutdown() {
        source?.cancel()
        source = nil
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 {
            source?.cancel()
            onClose(self)
            return
        }
        buffer.append(contentsOf: chunk.prefix(count))
        do {
            while let message = try FastqIPCFraming.decode(from: &buffer) {
                let response = handler(message)
                if let data = try? FastqIPCFraming.encode(response) {
                    data.withUnsafeBytes { raw in
                        if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                            _ = Darwin.write(fd, base, data.count)
                        }
                    }
                }
            }
        } catch {
            if let data = try? FastqIPCFraming.encode(.error(error.localizedDescription)) {
                data.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        _ = Darwin.write(fd, base, data.count)
                    }
                }
            }
        }
    }
}
