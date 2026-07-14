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
    /// When false, Space behaves normally (e.g. project picker open).
    var spaceHoldEnabled: Bool = true
    var onSubmit: () -> Void
    var onMentionQueryChange: (PromptMentionQuery?) -> Void
    var onMentionNavigate: ((Int) -> Void)?
    var onMentionConfirm: (() -> Void)?
    var onMentionCancel: (() -> Void)?
    var onSpaceHoldBegin: (() -> Void)?
    var onSpaceHoldEnd: (() -> Void)?
    var onSpaceHoldCancel: (() -> Void)?

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
        textView.spaceHoldEnabled = { [weak coordinator = context.coordinator] in
            coordinator?.parent.spaceHoldEnabled ?? true
        }
        textView.onSpaceHoldBegin = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSpaceHoldBegin?()
        }
        textView.onSpaceHoldEnd = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSpaceHoldEnd?()
        }
        textView.onSpaceHoldCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSpaceHoldCancel?()
        }
        textView.placeholderString = placeholder

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.startObservingFocusRequests()
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        // While listening, parent drives text via live STT — avoid caret fights.
        if textView.string != text, !textView.isSpaceHolding {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        } else if textView.string != text, textView.isSpaceHolding {
            textView.string = text
            let end = textView.string.utf16.count
            textView.setSelectedRange(NSRange(location: end, length: 0))
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
        textView.spaceHoldEnabled = { [weak coordinator = context.coordinator] in
            coordinator?.parent.spaceHoldEnabled ?? true
        }
        textView.onSpaceHoldBegin = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSpaceHoldBegin?()
        }
        textView.onSpaceHoldEnd = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSpaceHoldEnd?()
        }
        textView.onSpaceHoldCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSpaceHoldCancel?()
        }

        if isFocused, isEnabled {
            context.coordinator.focusPrompt(selectAll: false)
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
            focusObserver = NotificationCenter.default.addObserver(
                forName: .fastqFocusLauncherPrompt,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.focusPrompt(selectAll: true)
            }
        }

        func stopObservingFocusRequests() {
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
                self.focusObserver = nil
            }
        }

        func focusPrompt(selectAll: Bool) {
            guard parent.isEnabled, let textView else { return }
            guard let window = textView.window ?? NSApp.keyWindow else { return }

            window.makeKeyAndOrderFront(nil)
            if window.makeFirstResponder(textView) {
                if selectAll, !textView.string.isEmpty {
                    textView.selectAll(nil)
                } else {
                    let end = textView.string.utf16.count
                    textView.setSelectedRange(NSRange(location: end, length: 0))
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
            parent.onMentionQueryChange(Self.mentionQuery(in: textView))
        }

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
    var spaceHoldEnabled: (() -> Bool)?
    var onSpaceHoldBegin: (() -> Void)?
    var onSpaceHoldEnd: (() -> Void)?
    var onSpaceHoldCancel: (() -> Void)?

    private(set) var isSpaceHolding = false
    private var spaceHoldTimer: Timer?
    private var spaceKeyDown = false

    /// Hold threshold before Space becomes dictation (quick tap still inserts " ").
    private let holdThreshold: TimeInterval = 0.16

    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { needsDisplay = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        cancelSpaceHoldIfNeeded()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let mention = mentionActive?() == true
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isSpace = event.keyCode == 49
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Hold-Space → dictation (no modifiers, mentions closed).
        if isSpace,
           mods.isEmpty,
           spaceHoldEnabled?() == true,
           !mention {
            if event.isARepeat {
                return // swallow key-repeat while held
            }
            spaceKeyDown = true
            spaceHoldTimer?.invalidate()
            let timer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
                guard let self, self.spaceKeyDown, !self.isSpaceHolding else { return }
                self.isSpaceHolding = true
                self.onSpaceHoldBegin?()
            }
            RunLoop.main.add(timer, forMode: .common)
            spaceHoldTimer = timer
            return
        }

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
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHoldTimer?.invalidate()
            spaceHoldTimer = nil
            spaceKeyDown = false

            if isSpaceHolding {
                isSpaceHolding = false
                onSpaceHoldEnd?()
            } else if spaceHoldEnabled?() == true,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                // Quick tap → insert a normal space.
                insertText(" ", replacementRange: selectedRange())
            }
            return
        }
        super.keyUp(with: event)
    }

    private func cancelSpaceHoldIfNeeded() {
        spaceHoldTimer?.invalidate()
        spaceHoldTimer = nil
        spaceKeyDown = false
        if isSpaceHolding {
            isSpaceHolding = false
            onSpaceHoldCancel?()
        }
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
