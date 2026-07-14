import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Root (Arc wrap-chrome: frame color wraps an inset canvas)

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore
    /// Docked sidebar (Arc "pinned"). When false the whole panel — traffic
    /// lights included — lives off-screen and returns on left-edge hover.
    @State private var sidebarPinned = true
    /// Hover-summoned floating panel (only meaningful when unpinned).
    @State private var sidebarFloating = false
    @State private var floatHideWork: DispatchWorkItem?
    /// Live drag-reorder state (project path / tab id being dragged).
    @State private var draggingWorkspace: String?
    @State private var draggingSession: UUID?

    /// Outer chrome that wraps the canvas on every edge (Arc “frame”).
    private let chromeInset: CGFloat = 12
    private let sidebarWidth: CGFloat = 248
    /// Height of the sidebar header row (traffic lights + controls).
    private let topChromeHeight: CGFloat = 52

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Continuous wrap color — sidebar + top/right/bottom gutters are the same surface.
            TerminalTheme.chrome
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 0) {
                if sidebarPinned {
                    sidebarColumn
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                canvas
                    // Equal wrap when the sidebar is away; flush-to-sidebar gap
                    // when pinned. Hidden state is a clean uniform frame (Arc).
                    .padding(.top, chromeInset)
                    .padding(.trailing, chromeInset)
                    .padding(.bottom, chromeInset)
                    .padding(.leading, sidebarPinned ? 6 : chromeInset)
            }

            // Left-edge hot zone summons the floating sidebar when unpinned.
            if !sidebarPinned {
                Color.clear
                    .frame(width: 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { summonFloatingSidebar() }
                    }
            }

            // Floating sidebar: same panel, framed, hovering over the canvas.
            if !sidebarPinned && sidebarFloating {
                sidebarColumn
                    .frame(width: sidebarWidth)
                    .background(TerminalTheme.chrome)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 24, x: 6)
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .onHover { inside in
                        if inside {
                            floatHideWork?.cancel()
                        } else {
                            scheduleFloatingHide()
                        }
                    }
                    .zIndex(2)
            }
        }
        // Span the full window including the hidden-titlebar zone, so the
        // canvas top inset equals the other edges (the sidebar header row
        // reserves its own room for the traffic lights).
        .ignoresSafeArea()
        .frame(minWidth: 980, minHeight: 600)
        .preferredColorScheme(.dark)
        // Animate the frame like Arc. The PTY only sees the settled size —
        // TerminalSession debounces resize — so TUIs reflow exactly once.
        .animation(.easeInOut(duration: 0.22), value: sidebarPinned)
        .animation(.easeInOut(duration: 0.18), value: sidebarFloating)
        .onReceive(NotificationCenter.default.publisher(for: .fastqToggleTerminalSidebar)) { _ in
            togglePinned()
        }
        .background(WindowChromeApplier(color: NSColor(TerminalTheme.chrome)))
        // Traffic lights belong to the panel: gone while it's away, back when
        // the panel is docked or floating.
        .background(TrafficLightsVisibility(visible: sidebarPinned || sidebarFloating))
    }

    // MARK: - Sidebar state

    private func togglePinned() {
        sidebarPinned.toggle()
        sidebarFloating = false
        floatHideWork?.cancel()
    }

    private func summonFloatingSidebar() {
        floatHideWork?.cancel()
        sidebarFloating = true
    }

    private func scheduleFloatingHide() {
        floatHideWork?.cancel()
        let work = DispatchWorkItem { sidebarFloating = false }
        floatHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Sidebar (drawn on the wrap chrome)

    /// Traffic lights + panel controls: the top row of the sidebar itself,
    /// so hiding the sidebar takes the window controls with it (Arc).
    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            // Native traffic lights render in this cleared zone.
            Color.clear.frame(width: 64, height: 1)

            Button {
                togglePinned()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(sidebarPinned ? "Hide Sidebar (⌘S)" : "Pin Sidebar (⌘S)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: topChromeHeight)
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader

            Text("Projects")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.bottom, 5)

            if store.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No projects yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("Launch an agent from Fastq and it shows up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.workspaces) { workspace in
                            ProjectSidebarSection(
                                store: store,
                                workspace: workspace,
                                draggingWorkspace: $draggingWorkspace,
                                draggingSession: $draggingSession
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Canvas (inset terminal surface)

    private var canvas: some View {
        ZStack {
            if store.selectedSession != nil {
                // Keep every session host mounted — only hit-testing / opacity swap.
                ZStack {
                    ForEach(store.sessions) { session in
                        GhosttyTerminalHost(
                            session: session,
                            isActive: session.id == store.selectedSessionID
                        )
                        .opacity(session.id == store.selectedSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == store.selectedSessionID)
                        // Stable identity so sidebar toggle never remounts the PTY view.
                        .id(session.id)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 3)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.35))
            Text("Waiting for an agent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Open Fastq, pick a project, and launch an agent.\nIt will appear as a task under that project.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
            Button {
                store.createShellSession()
            } label: {
                Label("New Terminal", systemImage: "plus")
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Project → Task rows

private struct ProjectSidebarSection: View {
    @ObservedObject var store: TerminalSessionStore
    let workspace: TerminalWorkspace
    @Binding var draggingWorkspace: String?
    @Binding var draggingSession: UUID?

    private var sessions: [TerminalSession] {
        store.sessions(in: workspace.path)
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !store.collapsedWorkspaceIDs.contains(workspace.path) },
            set: { expanded in
                if expanded {
                    store.collapsedWorkspaceIDs.remove(workspace.path)
                } else {
                    store.collapsedWorkspaceIDs.insert(workspace.path)
                }
            }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(sessions) { session in
                TaskRow(
                    session: session,
                    isSelected: store.selectedSessionID == session.id,
                    onSelect: { store.select(session.id) },
                    onClose: { store.quit(session.id) }
                )
                .opacity(draggingSession == session.id ? 0.4 : 1)
                .onDrag {
                    draggingSession = session.id
                    return NSItemProvider(object: session.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: SessionDropDelegate(
                    target: session.id,
                    dragging: $draggingSession,
                    store: store
                ))
            }
        } label: {
            ProjectHeader(
                name: workspace.name,
                pathLabel: workspace.abbreviatedPath,
                taskCount: sessions.count,
                isRunning: sessions.contains(where: \.isRunning),
                onNewTerminal: {
                    store.createShellSession(at: workspace.path)
                },
                onCloseAll: {
                    for session in sessions {
                        store.quit(session.id)
                    }
                }
            )
            .opacity(draggingWorkspace == workspace.path ? 0.4 : 1)
            .onDrag {
                draggingWorkspace = workspace.path
                return NSItemProvider(object: workspace.path as NSString)
            }
            .onDrop(of: [.text], delegate: WorkspaceDropDelegate(
                target: workspace.path,
                dragging: $draggingWorkspace,
                store: store
            ))
        }
        .tint(.white.opacity(0.45))
    }
}

private struct ProjectHeader: View {
    let name: String
    let pathLabel: String
    let taskCount: Int
    let isRunning: Bool
    let onNewTerminal: () -> Void
    let onCloseAll: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TerminalTheme.accent)
                .frame(width: 14)

            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 0)

            if isRunning {
                Circle()
                    .fill(Color(red: 0.35, green: 0.78, blue: 0.45))
                    .frame(width: 5, height: 5)
            }

            if isHovering {
                Button(action: onNewTerminal) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("New Tab Here (⌘T)")
            } else if taskCount > 0 {
                Text("\(taskCount)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.09)))
            }
        }
        // Fixed content height so hover swaps (badge ↔ +) never reflow the list.
        .frame(height: 17)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovering = $0 }
        .help(pathLabel)
        .contextMenu {
            Button("New Terminal Here", action: onNewTerminal)
            Divider()
            Button("Close All Tasks", role: .destructive, action: onCloseAll)
        }
    }
}

private struct TaskRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: toolSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(session.isRunning ? TerminalTheme.accent : .white.opacity(0.3))
                    .frame(width: 14)

                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : (session.isRunning ? 0.65 : 0.45)))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                }
            }
            // Fixed content height so the hover close button never reflows
            // the rows beneath.
            .frame(height: 17)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.13) : (isHovering ? Color.white.opacity(0.05) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background(MiddleClickCatcher(action: onClose))
        .help(session.isRunning ? session.toolLabel : "Exited")
        .contextMenu {
            Button("Close Task", role: .destructive, action: onClose)
        }
        .padding(.leading, 14)
    }

    private var toolSymbol: String {
        switch session.tool {
        case "cursorCLI": return "chevron.left.forwardslash.chevron.right"
        case "claudeCode": return "sparkles"
        case "codexCLI": return "terminal"
        case "grokAgent": return "bolt.fill"
        case "openCode": return "rectangle.and.terminal"
        case TerminalSession.shellTool: return "terminal.fill"
        default: return "terminal"
        }
    }
}

// MARK: - Middle-click closes a tab (browser-style)

/// Hit-test-transparent view that closes the row on middle-click without
/// stealing left/right clicks from the SwiftUI row.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self,
                      event.buttonNumber == 2,
                      event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                self.action?()
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Drag-to-reorder (live reorder on hover, like Finder sidebar)

private struct WorkspaceDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let store: TerminalSessionStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            withAnimation(.easeInOut(duration: 0.15)) {
                store.moveWorkspace(dragging, to: target)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct SessionDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let store: TerminalSessionStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        MainActor.assumeIsolated {
            withAnimation(.easeInOut(duration: 0.15)) {
                store.moveSession(dragging, to: target)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private enum TerminalTheme {
    /// Arc-style wrap chrome (continuous frame behind sidebar + gutters).
    /// Clearly lighter than the canvas so the inset frame actually reads.
    static let chrome = Color(red: 0.175, green: 0.18, blue: 0.225)
    static let canvas = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)
}

// MARK: - Match NSWindow background to wrap chrome

private struct WindowChromeApplier: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = color
        window.isOpaque = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Empty unified toolbar: macOS centers the traffic lights in a
        // ~52pt titlebar, putting them on the sidebar header row's center
        // line (Arc keeps its window controls inside the sidebar header).
        if window.toolbar == nil {
            window.toolbar = NSToolbar(identifier: "fastq.titlebarSpacer")
        }
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
    }
}

// MARK: - Traffic lights follow the sidebar (Arc)

private struct TrafficLightsVisibility: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            guard let button = window.standardWindowButton(type) else { continue }
            if visible {
                button.isHidden = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    button.animator().alphaValue = 1
                }
            } else {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    button.animator().alphaValue = 0
                }, completionHandler: {
                    // Alpha-0 buttons still hit-test; hide to drop ghost clicks.
                    if !visible { button.isHidden = true }
                })
            }
        }
    }
}

