import Foundation

/// Shared mutable bridge between SwiftUI views and the panel controller for Esc / paste.
@MainActor
final class LauncherKeyRouter {
    static let shared = LauncherKeyRouter()

    var isLauncherVisible = false
    var isProjectPickerOpen = false

    var closePicker: (() -> Void)?
    var onDismissLauncher: (() -> Void)?
    var onEscape: (() -> Void)?
    var attachFiles: (([URL]) -> Void)?
}
