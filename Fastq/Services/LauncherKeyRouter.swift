import Foundation

/// Shared mutable bridge between SwiftUI views and the panel controller for Esc / paste.
@MainActor
final class LauncherKeyRouter {
    static let shared = LauncherKeyRouter()

    var isLauncherVisible = false
    var isProjectPickerOpen = false
    var isMentionPopupOpen = false

    var closePicker: (() -> Void)?
    var closeMentionPopup: (() -> Void)?
    var onDismissLauncher: (() -> Void)?
    var onEscape: (() -> Void)?
    var attachFiles: (([URL]) -> Void)?
    /// Synchronously focus the prompt text view (type-anywhere routing).
    var focusPromptNow: (() -> Void)?
    /// Esc while a chip has Tab-focus: returns true when it consumed the key.
    var clearControlFocus: (() -> Bool)?
}
