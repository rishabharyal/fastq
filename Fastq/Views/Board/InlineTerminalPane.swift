import SwiftUI
import AppKit

/// Small embedded terminal for the project inspector — quick commands (git
/// status, ls, a script) rooted at the linked project folder. This is *not* a
/// terminal window: it owns exactly one shell session for its project path and
/// keeps the Ghostty surface mounted for the pane's lifetime so the PTY stays
/// alive and scrollback survives tab switches (same rule as
/// `LauncherView.persistentTerminalLayer` — `InMemoryTerminalSession.receive`
/// drops bytes without an attached surface, so unmounting loses history).
struct InlineTerminalPane: View {
    let terminals: TerminalSessionStore
    let projectPath: String?
    let isActive: Bool

    /// Owns the lazily-created session so re-renders never fork a second shell.
    @StateObject private var model = InlineTerminalPaneModel()

    init(terminals: TerminalSessionStore, projectPath: String?, isActive: Bool) {
        self.terminals = terminals
        self.projectPath = projectPath
        self.isActive = isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.session {
                InlineTerminalHeaderBar(
                    session: session,
                    onRestart: { restartShell() },
                    onClear: { clearScreen(session) }
                )

                Rectangle()
                    .fill(FQTheme.border)
                    .frame(height: 1)

                terminalSurface(session)
            } else {
                emptyState
            }
        }
        .background(FQTheme.surface)
        .onAppear { startIfNeeded() }
        .onChange(of: isActive) { _, _ in startIfNeeded() }
        .onChange(of: projectPath) { _, _ in
            // A different folder means a different shell; drop the old one so
            // the next activation roots at the new path.
            model.discardSession(in: terminals)
            startIfNeeded()
        }
    }

    // MARK: - Terminal surface

    private func terminalSurface(_ session: TerminalSession) -> some View {
        InlineTerminalSurface(
            session: session,
            isActive: isActive,
            onRestart: { restartShell() }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: FQTheme.space2) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)

            Text("Link a project folder to use the terminal")
                .font(FQTheme.fontSmall)
                .foregroundStyle(FQTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FQTheme.space4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal unavailable. Link a project folder to use the terminal.")
    }

    // MARK: - Actions

    /// First activation forks the shell. No path, no session; no repeat forks.
    private func startIfNeeded() {
        guard isActive, let projectPath, model.session == nil else { return }
        // Hop off the current update pass — createShellSession publishes into
        // the shared store, which SwiftUI dislikes mid-render.
        DispatchQueue.main.async {
            guard isActive, model.session == nil else { return }
            model.createSession(in: terminals, at: projectPath)
        }
    }

    private func restartShell() {
        guard let projectPath else { return }
        model.discardSession(in: terminals)
        DispatchQueue.main.async {
            guard model.session == nil else { return }
            model.createSession(in: terminals, at: projectPath)
        }
    }

    /// Form feed — zsh/bash line editors treat it as clear-screen, and it is
    /// harmless if a program is in the foreground.
    private func clearScreen(_ session: TerminalSession) {
        guard session.isRunning else { return }
        session.write("\u{0C}")
    }
}

// MARK: - Surface

/// The Ghostty host plus its "shell exited" affordance.
///
/// This observes the session directly: when the parent owned the exited check it
/// never saw `isRunning` flip after launch, so the overlay stayed up over a live
/// shell and its background swallowed every click.
private struct InlineTerminalSurface: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onRestart: () -> Void

    var body: some View {
        ZStack {
            FQTheme.codeBackground

            // Stays in the tree for the pane's lifetime; visibility is
            // opacity/hit-testing only, never a remount.
            GhosttyTerminalHost(session: session, isActive: isActive)
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .id(session.id)

            if !session.isRunning {
                exitedOverlay
                    // Only a dead shell may intercept input.
                    .allowsHitTesting(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var exitedOverlay: some View {
        VStack(spacing: FQTheme.space3) {
            Spacer(minLength: 0)

            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(FQTheme.textTertiary)

            Text("Shell exited")
                .font(FQTheme.fontBodyMedium)
                .foregroundStyle(FQTheme.textPrimary)

            FQButton(
                title: "Restart",
                systemImage: "arrow.clockwise",
                variant: .secondary,
                size: .small,
                action: onRestart
            )
            .accessibilityLabel("Restart shell")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FQTheme.codeBackground.opacity(0.92))
    }
}

// MARK: - Header

/// Compact chrome above the surface. Split out so it can observe the session's
/// `isRunning` / `title` without the parent re-rendering the Ghostty host.
private struct InlineTerminalHeaderBar: View {
    @ObservedObject var session: TerminalSession
    let onRestart: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: FQTheme.space2) {
            Circle()
                .fill(session.isRunning ? FQTheme.success : FQTheme.textTertiary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(folderName)
                .font(FQTheme.fontSmall.weight(.medium))
                .foregroundStyle(FQTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)

            FQStatusPill(
                text: session.isRunning ? "Running" : "Exited",
                hue: session.isRunning ? .green : .gray
            )
            .accessibilityLabel(session.isRunning ? "Shell running" : "Shell exited")

            Spacer(minLength: FQTheme.space1)

            FQIconButton(
                systemImage: "arrow.clockwise",
                size: 22,
                iconSize: 10.5,
                help: "Restart shell",
                action: onRestart
            )
            .accessibilityLabel("Restart shell")

            FQIconButton(
                systemImage: "eraser",
                size: 22,
                iconSize: 10.5,
                help: "Clear",
                isDisabled: !session.isRunning,
                action: onClear
            )
            .accessibilityLabel("Clear terminal")
        }
        .padding(.horizontal, FQTheme.space3)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(FQTheme.surface)
    }

    private var folderName: String {
        let name = URL(fileURLWithPath: session.projectPath).lastPathComponent
        return name.isEmpty ? session.projectPath : name
    }
}

// MARK: - Session ownership

/// Holds the pane's one shell session across view re-renders.
///
/// Deliberately not `@MainActor` at type level so `@StateObject` can build it
/// from the view's default value; every method that touches the store or the
/// session is main-actor isolated instead.
private final class InlineTerminalPaneModel: ObservableObject {
    @Published private(set) var session: TerminalSession?

    @MainActor
    func createSession(in store: TerminalSessionStore, at path: String) {
        guard session == nil else { return }
        guard let created = store.createShellSession(at: path) else { return }
        session = created
    }

    /// Tear the shell down (restart / folder change). Normal pane teardown does
    /// *not* call this — SwiftUI can transiently drop the view, and killing the
    /// PTY there would throw away the user's scrollback.
    @MainActor
    func discardSession(in store: TerminalSessionStore) {
        guard let existing = session else { return }
        session = nil
        store.quit(existing.id)
    }
}
