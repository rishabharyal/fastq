import AppKit
import ApplicationServices

enum PermissionsHelper {
    /// Prompt for Accessibility and return current trust state.
    @discardableResult
    static func requestAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Trigger TCC Automation registration by talking to Terminal via Apple Events.
    static func requestAutomationAccess() {
        let script = """
        tell application "System Events"
            -- Touch System Events so Fastq appears under Automation.
            get name
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }

        // Also target Terminal — the app Fastq most often controls.
        let terminalScript = """
        tell application "Terminal"
            get name
        end tell
        """
        if let appleScript = NSAppleScript(source: terminalScript) {
            appleScript.executeAndReturnError(&error)
        }
    }

    static func openAccessibilitySettings() {
        openPrivacyPane(legacyAnchor: "Privacy_Accessibility", modernPath: "Privacy_Accessibility")
    }

    static func openAutomationSettings() {
        openPrivacyPane(legacyAnchor: "Privacy_Automation", modernPath: "Privacy_Automation")
    }

    private static func openPrivacyPane(legacyAnchor: String, modernPath: String) {
        let candidates = [
            // macOS 13+ System Settings
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?\(modernPath)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(modernPath)",
            // Older System Preferences
            "x-apple.systempreferences:com.apple.preference.security?\(legacyAnchor)",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
