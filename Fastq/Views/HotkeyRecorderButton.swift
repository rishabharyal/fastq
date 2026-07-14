import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click to record a new global launcher hotkey.
struct HotkeyRecorderButton: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt
    var onChange: (() -> Void)?

    @State private var isRecording = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    isRecording.toggle()
                    errorMessage = nil
                } label: {
                    Text(isRecording ? "Press shortcut…" : HotkeyShortcut.displayString(keyCode: keyCode, modifiers: modifiers))
                        .font(.system(.body, design: .rounded).monospaced())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minWidth: 110)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isRecording ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .background(
                    HotkeyCaptureRepresentable(isActive: $isRecording) { code, mods in
                        handleCapture(keyCode: code, modifiers: mods)
                    }
                )

                if keyCode != HotkeyShortcut.defaultKeyCode
                    || modifiers != HotkeyShortcut.defaultModifiers {
                    Button("Reset") {
                        keyCode = HotkeyShortcut.defaultKeyCode
                        modifiers = HotkeyShortcut.defaultModifiers
                        errorMessage = nil
                        isRecording = false
                        onChange?()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func handleCapture(keyCode capturedCode: UInt16, modifiers capturedMods: UInt) {
        if capturedCode == UInt16(kVK_Escape) {
            isRecording = false
            errorMessage = nil
            return
        }

        let cleaned = NSEvent.ModifierFlags(rawValue: capturedMods)
            .intersection([.command, .option, .control, .shift])
            .rawValue

        guard HotkeyShortcut.isValid(keyCode: capturedCode, modifiers: cleaned) else {
            errorMessage = "Use ⌘, ⌥, or ⌃ plus a key."
            return
        }

        keyCode = capturedCode
        modifiers = cleaned
        errorMessage = nil
        isRecording = false
        onChange?()
    }
}

/// Invisible view that installs a local key monitor while recording.
private struct HotkeyCaptureRepresentable: NSViewRepresentable {
    @Binding var isActive: Bool
    var onCapture: (UInt16, UInt) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onCapture = onCapture
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onCapture: onCapture)
    }

    final class Coordinator: NSObject {
        var isActive: Bool {
            didSet { syncMonitor() }
        }
        var onCapture: (UInt16, UInt) -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(isActive: Bool, onCapture: @escaping (UInt16, UInt) -> Void) {
            self.isActive = isActive
            self.onCapture = onCapture
        }

        func attach(to view: NSView) {
            self.view = view
            syncMonitor()
        }

        private func syncMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard isActive else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive else { return event }
                // Ignore pure modifier key-downs.
                if event.keyCode == UInt16(kVK_Command)
                    || event.keyCode == UInt16(kVK_Shift)
                    || event.keyCode == UInt16(kVK_Option)
                    || event.keyCode == UInt16(kVK_Control)
                    || event.keyCode == UInt16(kVK_RightCommand)
                    || event.keyCode == UInt16(kVK_RightShift)
                    || event.keyCode == UInt16(kVK_RightOption)
                    || event.keyCode == UInt16(kVK_RightControl) {
                    return nil
                }
                let mods = event.modifierFlags
                    .intersection([.command, .option, .control, .shift])
                    .rawValue
                DispatchQueue.main.async {
                    self.onCapture(event.keyCode, mods)
                }
                return nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
