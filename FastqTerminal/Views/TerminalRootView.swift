import SwiftUI
import AppKit

// MARK: - Root
// Agent-only: Fastq Terminal hosts the PTY; the launcher preview is the UX.
// This window is a simple fallback (⌘T / Dock) — no IDE chrome.

struct TerminalRootView: View {
    @ObservedObject var store: TerminalSessionStore

    var body: some View {
        VStack(spacing: 0) {
            if store.sessions.count > 1 {
                tabBar
                Divider().overlay(FastqTheme.hairline)
            }
            agentSurface
        }
        .background(FastqTheme.canvas)
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        .background(WindowBackgroundApplier(color: NSColor(FastqTheme.canvas)))
        .onReceive(NotificationCenter.default.publisher(for: .fastqToggleTerminalSidebar)) { _ in
            // No-op: projects sidebar removed; keep notification for menu compatibility.
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(store.sessions) { session in
                    SessionTabChip(
                        title: session.title,
                        subtitle: session.isRunning ? session.toolLabel : "Exited",
                        isSelected: store.selectedSessionID == session.id,
                        isRunning: session.isRunning,
                        onSelect: { store.select(session.id) },
                        onClose: { store.quit(session.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(FastqTheme.panelHeader)
    }

    private var agentSurface: some View {
        ZStack {
            if store.selectedSession != nil {
                ForEach(store.sessions) { session in
                    GhosttyTerminalHost(
                        session: session,
                        isActive: session.id == store.selectedSessionID
                    )
                    .opacity(session.id == store.selectedSessionID ? 1 : 0)
                    .allowsHitTesting(session.id == store.selectedSessionID)
                    .id(session.id)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FastqTheme.canvas)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("No agent yet")
                .font(.headline)
            Text("Launch from Fastq — this window hosts the session.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                store.createShellSession()
            } label: {
                Label("New Terminal", systemImage: "plus")
            }
            .controlSize(.regular)
            .keyboardShortcut("t", modifiers: .command)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab chip

private struct SessionTabChip: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isRunning ? Color(red: 0.35, green: 0.78, blue: 0.45) : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .opacity(hovering || isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Theme

enum FastqTheme {
    static let canvas = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panelHeader = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let hairline = Color.primary.opacity(0.1)
    static let accent = Color(red: 0.35, green: 0.62, blue: 1.0)
}

// MARK: - Window background

private struct WindowBackgroundApplier: NSViewRepresentable {
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
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.styleMask.remove(.fullSizeContentView)
        window.toolbar = nil
    }
}
