import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Root (cmux-style)

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore

    private let sidebarWidth: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Divider().overlay(Color.white.opacity(0.08))
            mainPane
        }
        .frame(minWidth: 1100, minHeight: 640)
        .background(TerminalTheme.background)
        .preferredColorScheme(.dark)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("fastq")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("\(store.sessions.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if store.workspaceGroups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No workspaces yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Launch an agent from Fastq and it will show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.workspaceGroups) { group in
                            workspaceGroupSection(group)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(TerminalTheme.sidebar)
    }

    private func workspaceGroupSection(_ group: TerminalWorkspaceGroup) -> some View {
        let collapsed = store.collapsedWorkspaceIDs.contains(group.id)

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                store.toggleCollapsed(group.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 10)
                    Text(group.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text("\(group.workspaces.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                ForEach(group.workspaces) { workspace in
                    let sessions = store.sessions(in: workspace.path)
                    let active = sessions.first { $0.id == store.selectedSessionID } ?? sessions.last
                    WorkspaceRow(
                        name: workspace.name,
                        pathLabel: workspace.abbreviatedPath,
                        statusLine: active?.statusLine ?? "Idle",
                        sessionCount: sessions.count,
                        isRunning: sessions.contains(where: \.isRunning),
                        isSelected: store.selectedWorkspacePath == workspace.path,
                        onSelect: { store.selectWorkspace(workspace.path) },
                        onClose: {
                            for session in sessions {
                                store.quit(session.id)
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: Main

    private var mainPane: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.white.opacity(0.08))
            if store.selectedSession != nil {
                // Keep all session views alive so scrollback survives tab switches.
                ZStack {
                    ForEach(store.sessions) { session in
                        TerminalEmulatorHost(
                            session: session,
                            isActive: session.id == store.selectedSessionID
                        )
                        .opacity(session.id == store.selectedSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == store.selectedSessionID)
                    }
                }
            } else {
                emptyState
            }
        }
        .background(TerminalTheme.background)
    }

    private var tabBar: some View {
        let tabs: [TerminalSession] = {
            if let path = store.selectedWorkspacePath {
                return store.sessions(in: path)
            }
            return store.sessions
        }()

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabs) { session in
                    TopTab(
                        title: session.title,
                        isSelected: store.selectedSessionID == session.id,
                        isRunning: session.isRunning,
                        onSelect: { store.selectedSessionID = session.id },
                        onClose: { store.quit(session.id) }
                    )
                }
                if tabs.isEmpty {
                    Text("No active tabs")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(height: 40)
        .background(TerminalTheme.tabBar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.35))
            Text("Waiting for an agent")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Open Fastq, pick a project, and launch an agent.\nIt will open as a workspace tab here.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar / tabs chrome

private struct WorkspaceRow: View {
    let name: String
    let pathLabel: String
    let statusLine: String
    let sessionCount: Int
    let isRunning: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        if sessionCount > 0 {
                            Text("\(sessionCount)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Circle().fill(TerminalTheme.accent))
                        }
                        Spacer(minLength: 0)
                        if isRunning {
                            Circle()
                                .fill(Color(red: 0.35, green: 0.78, blue: 0.45))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text(statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.white.opacity(0.4))
                        .lineLimit(1)
                    Text(pathLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .opacity(isSelected ? 1 : 0.6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? TerminalTheme.selection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TopTab: View {
    let title: String
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                Circle()
                    .fill(TerminalTheme.accent)
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white.opacity(0.92) : .white.opacity(0.45))
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .frame(maxWidth: 220)
    }
}

private enum TerminalTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let sidebar = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let tabBar = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let selection = Color(red: 0.18, green: 0.42, blue: 0.95).opacity(0.85)
    static let accent = Color(red: 0.25, green: 0.55, blue: 1.0)
}

// MARK: - SwiftTerm host

struct TerminalEmulatorHost: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.caretColor = NSColor(red: 0.45, green: 0.7, blue: 1.0, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.nativeBackgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        context.coordinator.attach(to: view)
        context.coordinator.bindOutput()
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.session = session
        if context.coordinator.terminalView !== nsView {
            context.coordinator.attach(to: nsView)
            context.coordinator.bindOutput()
        }
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.session.detachOutputHandler()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: TerminalSession
        weak var terminalView: TerminalView?

        init(session: TerminalSession) {
            self.session = session
        }

        func attach(to view: TerminalView) {
            terminalView = view
        }

        func bindOutput() {
            let session = self.session
            Task { @MainActor in
                session.attachOutputHandler { [weak self] data in
                    self?.feed(data)
                }
            }
        }

        func feed(_ data: Data) {
            guard let terminalView else { return }
            let bytes = Array(data)
            terminalView.feed(byteArray: bytes[...])
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let cols = UInt16(max(newCols, 1))
            let rows = UInt16(max(newRows, 1))
            Task { @MainActor in
                session.resize(cols: cols, rows: rows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            guard !title.isEmpty else { return }
            Task { @MainActor in
                session.statusLine = title
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in
                session.write(bytes: bytes)
            }
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
