import AppKit
import SwiftUI
import os

private let bannerLog = Logger(subsystem: "app.fastq.launcher", category: "realtime")

/// Shows notifications as floating banners in the top-right of the screen.
///
/// The fallback for when macOS will not deliver native notifications — most
/// commonly because the build is ad-hoc signed, which `UNUserNotificationCenter`
/// refuses outright. Being a menu-bar accessory app, Fastq usually has no window
/// to show an inline banner in, so this draws its own borderless panel.
@MainActor
final class FloatingBannerPresenter: RealtimeNotificationPresenting {

    private let onSelect: @MainActor (FastplayRealtimeNotification) -> Void
    private let visibleDuration: TimeInterval
    /// Newest first; index drives the vertical stacking offset.
    private var active: [BannerWindow] = []

    private static let width: CGFloat = 360
    private static let spacing: CGFloat = 10
    private static let margin: CGFloat = 16
    private static let maxVisible = 4

    init(
        visibleDuration: TimeInterval = 6,
        onSelect: @escaping @MainActor (FastplayRealtimeNotification) -> Void
    ) {
        self.visibleDuration = visibleDuration
        self.onSelect = onSelect
    }

    nonisolated func prepare() async {
        // Nothing to request: drawing our own panel needs no permission.
    }

    @discardableResult
    nonisolated func present(_ notification: FastplayRealtimeNotification) async -> Bool {
        await show(notification)
        return true
    }

    private func show(_ notification: FastplayRealtimeNotification) {
        // Menu-bar apps can be running with no screen attached (clamshell).
        guard let screen = NSScreen.main else {
            bannerLog.error("no screen available - cannot show banner")
            return
        }
        bannerLog.info("showing in-app banner (\(self.active.count + 1, privacy: .public) visible)")

        // Drop the oldest rather than letting a burst cover the screen.
        while active.count >= Self.maxVisible, let oldest = active.last {
            dismiss(oldest)
        }

        let window = BannerWindow(width: Self.width)
        window.configure(
            notification: notification,
            onTap: { [weak self, weak window] in
                guard let self, let window else { return }
                self.dismiss(window)
                self.onSelect(notification)
            },
            onClose: { [weak self, weak window] in
                guard let self, let window else { return }
                self.dismiss(window)
            }
        )

        active.insert(window, at: 0)
        layout(on: screen)
        window.orderFrontRegardless()
        window.fadeIn()

        // Auto-dismiss. Cancelled implicitly if the user dismisses first, since
        // `dismiss` is idempotent and the window will already be gone.
        Task { [weak self, weak window] in
            try? await Task.sleep(nanoseconds: UInt64(self?.visibleDuration ?? 6) * 1_000_000_000)
            guard let self, let window else { return }
            self.dismiss(window)
        }
    }

    private func dismiss(_ window: BannerWindow) {
        guard let index = active.firstIndex(where: { $0 === window }) else { return }
        active.remove(at: index)
        window.fadeOutAndClose()
        if let screen = NSScreen.main {
            layout(on: screen)
        }
    }

    /// Stacks banners downward from the top-right corner.
    private func layout(on screen: NSScreen) {
        let frame = screen.visibleFrame
        var y = frame.maxY - Self.margin

        for window in active {
            let height = window.frame.height
            y -= height
            window.setFrameOrigin(
                NSPoint(x: frame.maxX - Self.width - Self.margin, y: y)
            )
            y -= Self.spacing
        }
    }
}

// MARK: - Banner window

/// A borderless, non-activating panel hosting the banner content.
@MainActor
private final class BannerWindow: NSPanel {

    init(width: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 88),
            // `.nonactivatingPanel` keeps the user's keyboard focus where it is:
            // a notification must never steal focus from what they are typing in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Above normal windows but below the menu bar, and visible on whichever
        // Space the user is on — including over full-screen apps.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(
        notification: FastplayRealtimeNotification,
        onTap: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        let view = BannerView(notification: notification, onTap: onTap, onClose: onClose)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: frame.width, height: 88)
        contentView = hosting

        // Size to the content: bodies wrap to two lines and would otherwise clip.
        let fitting = hosting.fittingSize
        let height = max(72, fitting.height)
        setContentSize(NSSize(width: frame.width, height: height))
        hosting.frame = NSRect(x: 0, y: 0, width: frame.width, height: height)
    }

    func fadeIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.close()
        }
    }
}

// MARK: - Banner content

private struct BannerView: View {
    let notification: FastplayRealtimeNotification
    let onTap: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private var iconName: String {
        switch notification.kind {
        case .taskAssigned: return "person.crop.circle.badge.checkmark"
        case .commentMentioned, .taskMentioned: return "at.circle.fill"
        case .unknown: return "bell.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(notification.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
    }
}
