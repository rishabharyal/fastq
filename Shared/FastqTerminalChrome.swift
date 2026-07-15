import SwiftUI
import AppKit
import GhosttyTerminal

// MARK: - Shared engine

/// One Ghostty app + config shared by every surface in the process.
@MainActor
enum FastqTerminalEngine {
    static let controller: TerminalController = {
        // Prefer the user's real Ghostty config (theme, font, palette…) when
        // they have one, layering only Fastq's functional overrides on top.
        // Fall back to the built-in Afterglow theme otherwise.
        if let userConfig = userGhosttyConfigPath() {
            exposeGhosttyResourcesDir()
            return TerminalController(
                configSource: .file(userConfig),
                theme: .default,
                terminalConfiguration: TerminalConfiguration { builder in
                    applyFastqOverrides(&builder)
                }
            )
        }
        return TerminalController(theme: fastqTheme) { builder in
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(false)
            builder.withFontSize(13)
            builder.withFontThicken(true)
            applyFastqOverrides(&builder)
        }
    }()

    /// Non-cosmetic settings Fastq needs regardless of whose theme is active.
    private static func applyFastqOverrides(_ builder: inout TerminalConfiguration.Builder) {
        builder.withWindowPaddingX(10)
        builder.withWindowPaddingY(8)
        builder.withCustom("mouse-hide-while-typing", "true")

        for bind in [
            "super+c=copy_to_clipboard",
            "super+v=paste_from_clipboard",
            "super+a=select_all",
            "super+k=clear_screen",
            "super+equal=increase_font_size:1",
            "super+plus=increase_font_size:1",
            "super+minus=decrease_font_size:1",
            "super+zero=reset_font_size",
            "alt+left=esc:b",
            "alt+right=esc:f",
            "super+left=text:\\x01",
            "super+right=text:\\x05",
            "super+backspace=text:\\x15",
            "super+home=scroll_to_top",
            "super+end=scroll_to_bottom",
            "shift+page_up=scroll_page_up",
            "shift+page_down=scroll_page_down",
            "super+up=jump_to_prompt:-1",
            "super+down=jump_to_prompt:1",
        ] {
            builder.withCustom("keybind", bind)
        }
    }

    private static func userGhosttyConfigPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append("\(xdg)/ghostty/config")
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/.config/ghostty/config")
        candidates.append("\(home)/Library/Application Support/com.mitchellh.ghostty/config")
        return candidates.first { fm.fileExists(atPath: $0) }
    }

    private static func exposeGhosttyResourcesDir() {
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else { return }
        let resources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        if FileManager.default.fileExists(atPath: "\(resources)/themes") {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }
    }

    private static var fastqTheme: TerminalTheme {
        let dark = TerminalConfiguration { builder in
            builder.withBackground("121214")
            builder.withForeground("EBEBEB")
            builder.withCursorColor("73B3FF")
            builder.withSelectionBackground("2C3A4E")
            builder.withSelectionForeground("EBEBEB")
            builder.withPalette(0, color: "#1B1B1E")
            builder.withPalette(1, color: "#F06C75")
            builder.withPalette(2, color: "#8CC265")
            builder.withPalette(3, color: "#E5C07B")
            builder.withPalette(4, color: "#61AFEF")
            builder.withPalette(5, color: "#C678DD")
            builder.withPalette(6, color: "#56B6C2")
            builder.withPalette(7, color: "#D7DAE0")
            builder.withPalette(8, color: "#5F6672")
            builder.withPalette(9, color: "#FF7B86")
            builder.withPalette(10, color: "#A5E075")
            builder.withPalette(11, color: "#F0C674")
            builder.withPalette(12, color: "#73B3FF")
            builder.withPalette(13, color: "#D58AEC")
            builder.withPalette(14, color: "#66D9E8")
            builder.withPalette(15, color: "#FFFFFF")
        }
        return TerminalTheme(light: dark, dark: dark)
    }
}

extension Notification.Name {
    /// Posted by menu items; the active session's host performs the Ghostty
    /// binding action (object is the action string, e.g. "clear_screen").
    static let fastqTerminalBindingAction = Notification.Name("fastq.terminalBindingAction")
}

// MARK: - Surface view with a context menu

/// TerminalView that always offers a right-click context menu. The base view
/// forwards right-clicks to the terminal as mouse input and only shows a menu
/// when clicking an existing selection — standard-terminal behavior (Copy /
/// Paste / Select All / Clear) is friendlier for this app.
final class FastqSurfaceView: TerminalView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteClipboard()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func pasteClipboard() {
        if performBindingAction("paste_from_clipboard") { return }
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            sendText(text)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {
        // Swallowed — the context menu owns this click.
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Copy", action: #selector(menuCopy), key: "c"))
        menu.addItem(item("Paste", action: #selector(menuPaste), key: "v"))
        menu.addItem(item("Select All", action: #selector(menuSelectAll), key: "a"))
        menu.addItem(.separator())
        menu.addItem(item("Clear", action: #selector(menuClear), key: "k"))
        return menu
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        return item
    }

    @objc private func menuCopy() { _ = performBindingAction("copy_to_clipboard") }
    @objc private func menuPaste() { pasteClipboard() }
    @objc private func menuSelectAll() { _ = performBindingAction("select_all") }
    @objc private func menuClear() { _ = performBindingAction("clear_screen") }
}
