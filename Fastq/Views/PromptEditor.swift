import SwiftUI
import AppKit

extension Notification.Name {
    static let fastqFocusLauncherPrompt = Notification.Name("fastq.focusLauncherPrompt")
}

struct PromptMentionQuery: Equatable {
    /// Text after `@` (may be empty).
    var filter: String
    /// UTF-16 range of `@…` in the prompt (including the `@`).
    var range: NSRange
}

/// Multiline prompt field: Return submits, Shift+Return inserts a newline.
/// Typing `@` surfaces a file-mention query to the parent.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var isFocused: Bool
    var mentionActive: Bool
    /// True while mic dictation streams into `text` — keeps the caret at the end.
    var isDictating: Bool = false
    var onSubmit: () -> Void
    var onMentionQueryChange: (PromptMentionQuery?) -> Void
    var onMentionNavigate: ((Int) -> Void)?
    var onMentionConfirm: (() -> Void)?
    var onMentionCancel: (() -> Void)?
    /// Reports the text's natural height (clamped by the caller) so the
    /// editor hugs its content instead of reserving its max height.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = PromptNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 16, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.handleSubmit()
        }
        textView.onMentionNavigate = { [weak coordinator = context.coordinator] delta in
            coordinator?.parent.onMentionNavigate?(delta)
        }
        textView.onMentionConfirm = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onMentionConfirm?()
        }
        textView.onMentionCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onMentionCancel?()
        }
        textView.mentionActive = { [weak coordinator = context.coordinator] in
            coordinator?.parent.mentionActive ?? false
        }
        textView.placeholderString = placeholder

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.startObservingFocusRequests()
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.reportHeight()
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        // While listening, parent drives text via live STT — avoid caret fights.
        if textView.string != text, !isDictating {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
            context.coordinator.applyMentionHighlight()
        } else if textView.string != text, isDictating {
            textView.string = text
            let end = textView.string.utf16.count
            textView.setSelectedRange(NSRange(location: end, length: 0))
            context.coordinator.applyMentionHighlight()
        }

        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.placeholderString = placeholder
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.handleSubmit()
        }
        textView.onMentionNavigate = { [weak coordinator = context.coordinator] delta in
            coordinator?.parent.onMentionNavigate?(delta)
        }
        textView.onMentionConfirm = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onMentionConfirm?()
        }
        textView.onMentionCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onMentionCancel?()
        }
        textView.mentionActive = { [weak coordinator = context.coordinator] in
            coordinator?.parent.mentionActive ?? false
        }

        if isFocused, isEnabled {
            context.coordinator.focusPrompt(selectAll: false)
        }

        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.reportHeight()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingFocusRequests()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var textView: PromptNSTextView?
        private var focusObserver: NSObjectProtocol?

        init(_ parent: PromptEditor) {
            self.parent = parent
        }

        func startObservingFocusRequests() {
            stopObservingFocusRequests()
            MainActor.assumeIsolated {
                LauncherKeyRouter.shared.focusPromptNow = { [weak self] in
                    self?.focusPrompt(selectAll: false)
                }
            }
            focusObserver = NotificationCenter.default.addObserver(
                forName: .fastqFocusLauncherPrompt,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let caret = note.userInfo?["caret"] as? Int
                self?.focusPrompt(selectAll: caret == nil, caret: caret)
            }
        }

        func stopObservingFocusRequests() {
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
                self.focusObserver = nil
            }
        }

        func focusPrompt(selectAll: Bool, caret: Int? = nil) {
            guard parent.isEnabled, let textView else { return }
            guard let window = textView.window ?? NSApp.keyWindow else { return }

            window.makeKeyAndOrderFront(nil)
            if window.makeFirstResponder(textView) {
                let length = textView.string.utf16.count
                if let caret {
                    textView.setSelectedRange(NSRange(location: min(max(caret, 0), length), length: 0))
                } else if selectAll, !textView.string.isEmpty {
                    textView.selectAll(nil)
                } else {
                    textView.setSelectedRange(NSRange(location: length, length: 0))
                }
            }
        }

        func handleSubmit() {
            if parent.mentionActive {
                parent.onMentionConfirm?()
            } else {
                parent.onSubmit()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyMentionHighlight()
            reportHeight()
            parent.onMentionQueryChange(Self.mentionQuery(in: textView))
        }

        func reportHeight() {
            guard let textView,
                  let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let height = layoutManager.usedRect(for: container).height
                + textView.textContainerInset.height * 2
            parent.onHeightChange?(height)
        }

        /// Tint `@file` mentions so they read as tokens, not prose. Uses
        /// layout-manager temporary attributes: purely visual, never touches
        /// the plain string that gets submitted.
        func applyMentionHighlight() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let ns = textView.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            Self.mentionTokenRegex.enumerateMatches(in: textView.string, range: full) { match, _, _ in
                guard let range = match?.range else { return }
                // Token must start the text or follow whitespace (same rule
                // as the live mention query) — emails etc. stay untinted.
                if range.location > 0 {
                    let prev = ns.character(at: range.location - 1)
                    guard let scalar = UnicodeScalar(prev),
                          CharacterSet.whitespacesAndNewlines.contains(scalar) else { return }
                }
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: NSColor.controlAccentColor,
                    forCharacterRange: range
                )
            }
        }

        private static let mentionTokenRegex = try! NSRegularExpression(pattern: "@[^\\s@]+")

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.onMentionQueryChange(Self.mentionQuery(in: textView))
        }

        static func mentionQuery(in textView: NSTextView) -> PromptMentionQuery? {
            let string = textView.string as NSString
            let cursor = textView.selectedRange().location
            guard cursor != NSNotFound, cursor <= string.length else { return nil }

            // Walk left from caret to find an active `@token`.
            var i = cursor
            while i > 0 {
                let ch = string.character(at: i - 1)
                if ch == UInt16(UnicodeScalar("@").value) {
                    let atIndex = i - 1
                    // `@` must start a token (start or after whitespace/newline).
                    if atIndex > 0 {
                        let prev = string.character(at: atIndex - 1)
                        if let scalar = UnicodeScalar(prev),
                           !CharacterSet.whitespacesAndNewlines.contains(scalar),
                           scalar != "\n" {
                            return nil
                        }
                    }
                    let filterRange = NSRange(location: atIndex + 1, length: cursor - (atIndex + 1))
                    let filter = string.substring(with: filterRange)
                    // Stop mention if filter contains whitespace (token ended).
                    if filter.contains(where: { $0.isWhitespace }) {
                        return nil
                    }
                    let fullRange = NSRange(location: atIndex, length: cursor - atIndex)
                    return PromptMentionQuery(filter: filter, range: fullRange)
                }
                if let scalar = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    return nil
                }
                i -= 1
            }
            return nil
        }

        deinit {
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
            }
        }
    }
}

final class PromptNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onMentionNavigate: ((Int) -> Void)?
    var onMentionConfirm: (() -> Void)?
    var onMentionCancel: (() -> Void)?
    var mentionActive: (() -> Bool)?

    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { needsDisplay = true }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let mention = mentionActive?() == true
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if mention {
            if event.keyCode == 125 {
                onMentionNavigate?(1)
                return
            }
            if event.keyCode == 126 {
                onMentionNavigate?(-1)
                return
            }
            if event.keyCode == 48 || (isReturn && !event.modifierFlags.contains(.shift)) {
                onMentionConfirm?()
                return
            }
            if event.keyCode == 53 {
                onMentionCancel?()
                return
            }
        }

        if isReturn {
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                onSubmit?()
            }
            return
        }

        // Fallback when the local NSEvent monitor does not consume ↑/↓
        // (e.g. SwiftUI state timing). Raycast-style: route into Active Windows.
        if mods.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
            if LauncherKeyRouter.shared.handleArrowKey?(event.keyCode == 126) == true {
                return
            }
        }

        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 5, y: inset.height)
        placeholderString.draw(at: origin, withAttributes: attrs)
    }
}
