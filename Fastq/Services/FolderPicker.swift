import AppKit

/// Presents `NSOpenPanel` above Fastq's floating launcher.
enum FolderPicker {
    @MainActor
    static func chooseDirectories(
        message: String = "Choose repositories or project folders",
        prompt: String = "Add",
        allowingMultiple: Bool = true,
        preparing: (() -> Void)? = nil,
        completion: @escaping ([URL]) -> Void
    ) {
        preparing?()
        present(
            configure: { panel in
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = allowingMultiple
                panel.canCreateDirectories = false
                panel.message = message
                panel.prompt = prompt
            },
            completion: completion
        )
    }

    @MainActor
    static func chooseFiles(
        allowingMultiple: Bool = true,
        preparing: (() -> Void)? = nil,
        completion: @escaping ([URL]) -> Void
    ) {
        preparing?()
        present(
            configure: { panel in
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = allowingMultiple
            },
            completion: completion
        )
    }

    @MainActor
    private static func present(
        configure: (NSOpenPanel) -> Void,
        completion: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        configure(panel)
        // Above `.floating` launcher / onboarding panels.
        panel.level = .modalPanel
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Drop floating windows briefly so the picker can't end up behind them.
        let restoredLevels = NSApp.windows.compactMap { window -> (NSWindow, NSWindow.Level)? in
            guard window.level >= .floating, window !== panel else { return nil }
            let previous = window.level
            window.level = .normal
            return (window, previous)
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()

        for (window, level) in restoredLevels {
            window.level = level
        }

        completion(response == .OK ? panel.urls : [])
    }
}
