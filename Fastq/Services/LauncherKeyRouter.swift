import Foundation

/// Shared mutable bridge between SwiftUI views and the panel controller for Esc / paste.
@MainActor
final class LauncherKeyRouter {
    static let shared = LauncherKeyRouter()

    var isLauncherVisible = false
    var isProjectPickerOpen = false
    var isMentionPopupOpen = false
    var isSessionPreviewOpen = false

    var closePicker: (() -> Void)?
    /// When the agent chat preview is open, pasted/dropped files land in the
    /// chat composer instead of the main prompt.
    var chatComposerAttach: (([URL]) -> Void)?
    var closeSessionPreview: (() -> Void)?
    var closeMentionPopup: (() -> Void)?
    var onDismissLauncher: (() -> Void)?
    var onEscape: (() -> Void)?
    var attachFiles: (([URL]) -> Void)?
    /// Synchronously focus the prompt text view (type-anywhere routing).
    var focusPromptNow: (() -> Void)?
    /// Esc while a chip has Tab-focus: returns true when it consumed the key.
    var clearControlFocus: (() -> Bool)?
    /// ↑/↓ while the prompt is first responder — returns true when consumed
    /// (Active Windows list / prompt history). Wired from `LauncherView`.
    var handleArrowKey: ((Bool) -> Bool)?
}
