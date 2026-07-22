import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Composer bar

/// Full-featured agent chat composer: auto-growing input, attachment chips
/// (drag-and-drop + paste), a real toolbar row (model / permission mode /
/// attach / mic) and a send button that becomes a stop control while busy.
///
/// Drop-in superset of `AgentChatComposer` — every parameter of the old
/// composer is kept with the same name, type and default; everything new is
/// optional and declared before `onSubmit` so trailing-closure call sites keep
/// working unchanged.
struct AgentComposerBar: View {
    // Original AgentChatComposer surface (order preserved).
    @Binding var text: String
    @Binding var attachments: [PromptAttachment]
    var placeholder = "Ask anything"
    var isBusy = false
    /// Cursor's client-side queue depth, shown as a hint.
    var queuedCount = 0
    @Binding var permissionPreset: AgentPermissionPreset
    @Binding var model: AgentModelOption
    var showsModelPicker = true
    var onAttach: (() -> Void)?
    var onMic: (() -> Void)?
    var isListening = false
    var onStop: (() -> Void)?

    // New, optional.
    /// Models offered by the model picker.
    var modelOptions: [AgentModelOption] = [.auto, .fable, .opus, .sonnet, .haiku]
    /// Hide the permission-mode menu (e.g. tools that don't support presets).
    var showsPermissionPicker = true
    /// Disables typing and every control.
    var isEnabled = true
    /// Height clamp for the input, in text lines.
    var minLines = 1
    var maxLines = 10
    /// Optional left-most toolbar chip — usually the project / working folder.
    var contextLabel: String?
    var contextSystemImage = "folder"
    var onContextTap: (() -> Void)?
    /// Called with URLs added by drop / paste so the host can persist them.
    var onAttachURLs: (([URL]) -> Void)?
    /// Shown as a "Clear" affordance next to the queued badge when provided.
    var onClearQueue: (() -> Void)?
    /// Soft character budget — a counter appears past 60% of it.
    var characterBudget: Int?

    var onSubmit: () -> Void

    @StateObject private var focusProxy = AgentComposerFocusProxy()
    @State private var textHeight: CGFloat = 0
    @State private var isFocused = false
    @State private var isDropTargeted = false

    // MARK: Metrics

    private static let editorFont = NSFont.systemFont(ofSize: 13)
    private static var lineHeight: CGFloat {
        ceil(editorFont.ascender - editorFont.descender + editorFont.leading)
    }
    private static let editorVerticalInset: CGFloat = 4

    private var minEditorHeight: CGFloat {
        Self.lineHeight * CGFloat(max(minLines, 1)) + Self.editorVerticalInset * 2
    }

    private var maxEditorHeight: CGFloat {
        Self.lineHeight * CGFloat(max(maxLines, max(minLines, 1))) + Self.editorVerticalInset * 2
    }

    private var editorHeight: CGFloat {
        min(max(textHeight, minEditorHeight), maxEditorHeight)
    }

    // MARK: State

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        isEnabled && (!trimmed.isEmpty || !attachments.isEmpty)
    }

    private var borderColor: Color {
        if isDropTargeted { return FQTheme.accent }
        return isFocused ? FQTheme.focusRing : FQTheme.border
    }

    private var borderWidth: CGFloat {
        (isFocused || isDropTargeted) ? 2 : 1
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            statusRow

            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    attachmentRow
                }
                editorRow
                toolbarRow
            }
            .background(FQTheme.surface, in: RoundedRectangle(cornerRadius: FQTheme.radiusLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FQTheme.radiusLarge, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .overlay(alignment: .center) {
                if isDropTargeted {
                    dropHint
                }
            }
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
            .animation(.easeOut(duration: 0.12), value: editorHeight)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            footerRow
        }
    }

    // MARK: Status (busy / queued)

    @ViewBuilder
    private var statusRow: some View {
        if isBusy || queuedCount > 0 {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                    Text("Working…")
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textSecondary)
                }
                if queuedCount > 0 {
                    FQBadge(
                        text: "\(queuedCount) queued",
                        tone: .accent,
                        systemImage: "clock"
                    )
                    .help("\(queuedCount) message\(queuedCount == 1 ? "" : "s") queued — sends when this run finishes")
                    .accessibilityLabel("\(queuedCount) message\(queuedCount == 1 ? "" : "s") queued")

                    if let onClearQueue {
                        Button("Clear", action: onClearQueue)
                            .buttonStyle(.plain)
                            .font(FQTheme.fontCaption.weight(.medium))
                            .foregroundStyle(FQTheme.textSecondary)
                            .help("Discard queued messages")
                            .accessibilityLabel("Clear queued messages")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .transition(.opacity)
        }
    }

    // MARK: Attachments

    private var attachmentRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(attachments) { attachment in
                AgentComposerAttachmentChip(attachment: attachment) {
                    remove(attachment)
                }
            }
        }
        .padding(.horizontal, FQTheme.space3)
        .padding(.top, FQTheme.space2)
        .accessibilityLabel("\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")")
    }

    // MARK: Input

    private var editorRow: some View {
        AgentComposerTextEditor(
            text: $text,
            placeholder: placeholder,
            isEnabled: isEnabled,
            font: Self.editorFont,
            verticalInset: Self.editorVerticalInset,
            proxy: focusProxy,
            onSubmit: submitIfPossible,
            onFiles: { addAttachments($0) },
            onHeightChange: { height in
                if abs(height - textHeight) > 0.5 { textHeight = height }
            },
            onFocusChange: { isFocused = $0 }
        )
        .frame(height: editorHeight)
        .padding(.horizontal, FQTheme.space3 - 5) // text container lineFragmentPadding
        .padding(.top, attachments.isEmpty ? FQTheme.space2 : 6)
        .contentShape(Rectangle())
        .onTapGesture { focusProxy.focus() }
        .accessibilityLabel(placeholder)
    }

    // MARK: Toolbar

    private var toolbarRow: some View {
        HStack(spacing: 6) {
            if let contextLabel, !contextLabel.isEmpty {
                Button {
                    onContextTap?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: contextSystemImage)
                            .font(.system(size: 10, weight: .medium))
                        Text(contextLabel)
                            .font(FQTheme.fontSmall.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(FQTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        FQTheme.surfaceSecondary,
                        in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onContextTap == nil)
                .help(contextLabel)
                .accessibilityLabel("Context: \(contextLabel)")
            }

            if showsModelPicker {
                FQMenuChip(title: model.displayName, systemImage: "sparkles") {
                    ForEach(modelOptions) { option in
                        Button {
                            model = option
                        } label: {
                            if option == model {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                }
                .disabled(!isEnabled)
                .help("Model — \(model.displayName)")
                .accessibilityLabel("Model, \(model.displayName)")
            }

            if showsPermissionPicker {
                FQMenuChip(title: permissionPreset.displayName, systemImage: permissionPreset.systemImage) {
                    Section("Permission mode") {
                        ForEach(AgentPermissionPreset.allCases) { preset in
                            Button {
                                permissionPreset = preset
                            } label: {
                                if preset == permissionPreset {
                                    Label("\(preset.displayName) — \(preset.detail)", systemImage: "checkmark")
                                } else {
                                    Text("\(preset.displayName) — \(preset.detail)")
                                }
                            }
                        }
                    }
                }
                .disabled(!isEnabled)
                .help("Permission mode — \(permissionPreset.detail)")
                .accessibilityLabel("Permission mode, \(permissionPreset.displayName)")
            }

            Spacer(minLength: 0)

            if let budget = characterBudget, text.count > (budget * 3) / 5 {
                Text("\(text.count)/\(budget)")
                    .font(FQTheme.fontCaption.monospacedDigit())
                    .foregroundStyle(text.count > budget ? FQTheme.danger : FQTheme.textTertiary)
                    .accessibilityLabel("\(text.count) of \(budget) characters")
            }

            if let onAttach {
                FQIconButton(
                    systemImage: "paperclip",
                    size: 26,
                    iconSize: 12,
                    help: "Attach files",
                    isDisabled: !isEnabled
                ) {
                    onAttach()
                }
            }

            if let onMic {
                FQIconButton(
                    systemImage: isListening ? "mic.fill" : "mic",
                    size: 26,
                    iconSize: 12,
                    tint: isListening ? FQTheme.danger : nil,
                    help: isListening ? "Stop dictation" : "Dictate",
                    isDisabled: !isEnabled
                ) {
                    onMic()
                }
                .accessibilityLabel(isListening ? "Stop dictation" : "Start dictation")
            }

            if isBusy, let onStop {
                FQIconButton(
                    systemImage: "stop.fill",
                    size: 28,
                    iconSize: 10.5,
                    help: "Stop this run"
                ) {
                    onStop()
                }
                .accessibilityLabel("Stop this run")
                .keyboardShortcut(".", modifiers: .command)
            }

            FQIconButton(
                systemImage: "arrow.up",
                size: 28,
                iconSize: 12.5,
                filled: true,
                help: isBusy ? "Send — runs as the next turn" : "Send (Return)",
                isDisabled: !canSubmit
            ) {
                submitIfPossible()
            }
            .accessibilityLabel(isBusy ? "Send, queues as the next turn" : "Send message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Footer hints

    @ViewBuilder
    private var footerRow: some View {
        if isFocused || !trimmed.isEmpty {
            HStack(spacing: 8) {
                Text("Return to send · Shift-Return for a new line")
                    .font(FQTheme.fontCaption)
                    .foregroundStyle(FQTheme.textTertiary)
                Spacer(minLength: 0)
                if !attachments.isEmpty {
                    Text("\(attachments.count) file\(attachments.count == 1 ? "" : "s") attached")
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textTertiary)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    private var dropHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("Drop files to attach")
                .font(FQTheme.fontSmall.weight(.semibold))
        }
        .foregroundStyle(FQTheme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(FQTheme.surface.opacity(0.95), in: Capsule())
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func submitIfPossible() {
        guard canSubmit else { return }
        onSubmit()
    }

    private func remove(_ attachment: PromptAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func addAttachments(_ urls: [URL]) {
        var added: [URL] = []
        for url in urls where !attachments.contains(where: { $0.path == url.path }) {
            attachments.append(PromptAttachment(url: url))
            added.append(url)
        }
        if !added.isEmpty {
            onAttachURLs?(added)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty, isEnabled else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    addAttachments([url])
                }
            }
        }
        return true
    }
}

// MARK: - Attachment chip

/// Attachment pill with an image thumbnail (or a file glyph) and its own
/// remove button.
struct AgentComposerAttachmentChip: View {
    let attachment: PromptAttachment
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            thumbnail
            Text(attachment.name)
                .font(FQTheme.fontSmall.weight(.medium))
                .foregroundStyle(FQTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(FQTheme.textSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.name)")
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            isHovering ? FQTheme.surfaceHover : FQTheme.surfaceSecondary,
            in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
        )
        .onHover { isHovering = $0 }
        .help(attachment.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment \(attachment.name)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(FQTheme.textSecondary)
                .frame(width: 18, height: 18)
        }
    }
}

// MARK: - Growing text editor

/// Focus handle so tapping the composer's padding puts the caret in the
/// text view.
final class AgentComposerFocusProxy: ObservableObject {
    weak var textView: NSTextView?

    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }
}

/// Auto-sizing multi-line editor. Return submits, Shift/Option-Return inserts
/// a newline, Command-Return submits, and pasting files or image data attaches
/// instead of inserting a path.
struct AgentComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var font: NSFont
    var verticalInset: CGFloat
    var proxy: AgentComposerFocusProxy
    var onSubmit: () -> Void
    var onFiles: ([URL]) -> Void
    var onHeightChange: (CGFloat) -> Void
    var onFocusChange: (Bool) -> Void

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

        let textView = AgentComposerNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.placeholderString = placeholder
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onFiles(urls)
        }
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        textView.setAccessibilityLabel(placeholder)

        scroll.documentView = textView
        context.coordinator.textView = textView
        proxy.textView = textView

        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.reportHeight()
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            let length = textView.string.utf16.count
            // Restore the caret when it still fits (external edits — dictation,
            // history recall — otherwise fall to the end).
            if let first = selected.first?.rangeValue, NSMaxRange(first) <= length {
                textView.selectedRanges = selected
            } else {
                textView.setSelectedRange(NSRange(location: length, length: 0))
            }
        }

        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.font = font
        textView.placeholderString = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onFiles(urls)
        }
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        proxy.textView = textView

        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.reportHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentComposerTextEditor
        weak var textView: AgentComposerNSTextView?

        init(_ parent: AgentComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func reportHeight() {
            guard let textView,
                  let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let height = layoutManager.usedRect(for: container).height
                + textView.textContainerInset.height * 2
            parent.onHeightChange(ceil(height))
        }
    }
}

/// NSTextView with composer key handling, file paste and a drawn placeholder.
final class AgentComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            needsDisplay = true
            onFocusChange?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            needsDisplay = true
            onFocusChange?(false)
        }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            let modifiers = event.modifierFlags
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                super.keyDown(with: event)
            } else {
                // Plain Return and Command-Return both send.
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let hasFiles = pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        let hasText = pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
        let hasImage = pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil

        if hasFiles || (hasImage && !hasText) {
            let urls = PasteboardFiles.read()
            if !urls.isEmpty {
                onFiles?(urls)
                return
            }
        }
        super.paste(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 5
        placeholderString.draw(
            at: NSPoint(x: inset.width + padding, y: inset.height),
            withAttributes: attrs
        )
    }
}
