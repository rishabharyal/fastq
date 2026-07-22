import SwiftUI

// MARK: - Tool call group

/// Collapsible "🔧 N tool calls" block with per-call status rows.
struct ToolCallGroup: View {
    let calls: [ToolCallRecord]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(calls.count) tool call\(calls.count == 1 ? "" : "s")")
                        .font(FQTheme.fontSmall.weight(.medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(FQTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(calls.count) tool calls, \(expanded ? "collapse" : "expand")")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls) { call in
                        ToolCallRow(call: call)
                    }
                }
            }
        }
    }
}

/// One tool call: the compact one-liner, disclosable into the full
/// inspector (diff / command output / file contents).
struct ToolCallRow: View {
    let call: ToolCallRecord

    @State private var expanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            summaryRow
            if expanded, call.hasDetail {
                ToolCallDetailView(call: call)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var summaryRow: some View {
        Button {
            guard call.hasDetail else { return }
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                statusIcon
                Text(call.name)
                    .font(FQTheme.fontMono.weight(.medium))
                    .foregroundStyle(FQTheme.textSecondary)
                if call.isSubagent {
                    FQBadge(text: "subagent", tone: .neutral)
                }
                if !call.summary.isEmpty {
                    Text(call.summary)
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let duration = call.durationLabel {
                    Text(duration)
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textTertiary)
                }
                if call.hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isHovering || expanded ? FQTheme.textSecondary : FQTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                isHovering && call.hasDetail ? FQTheme.surfaceSecondary : .clear,
                in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(!call.hasDetail)
        .help(call.hasDetail ? (expanded ? "Hide details" : "Show details") : "")
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["\(call.name) \(call.summary)"]
        if call.ok == false { parts.append("failed") }
        if call.hasDetail { parts.append(expanded ? "expanded, collapse details" : "collapsed, expand details") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if call.finishedAt == nil {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: call.ok == false ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(call.ok == false ? FQTheme.danger : FQTheme.success)
        }
    }
}

// MARK: - Question card (AskUserQuestion)

/// Claude's clarifying questions as a one-at-a-time carousel (like the
/// terminal UI): header tabs across the top, one question visible,
/// single-select auto-advances, last answer submits.
struct QuestionCard: View {
    let record: QuestionRecord
    let isPending: Bool
    var onAnswer: ([String: String]) -> Void

    @State private var currentIndex = 0
    @State private var selections: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]

    var body: some View {
        FQCard(radius: FQTheme.radiusMedium, padding: FQTheme.space3) {
            VStack(alignment: .leading, spacing: FQTheme.space3) {
                if record.answered || !isPending {
                    answeredSummary
                } else {
                    if record.questions.count > 1 {
                        stepTabs
                    }
                    if let question = currentQuestion {
                        carouselQuestion(question)
                            .id(question.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: currentIndex)
        }
    }

    private var currentQuestion: AskQuestion? {
        guard record.questions.indices.contains(currentIndex) else { return nil }
        return record.questions[currentIndex]
    }

    private var isLastQuestion: Bool {
        currentIndex >= record.questions.count - 1
    }

    // MARK: - Step tabs ("Next task · Verification" + progress)

    private var stepTabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(record.questions.enumerated()), id: \.element.id) { index, question in
                let isCurrent = index == currentIndex
                let isDone = answer(for: question) != nil && index != currentIndex
                Button {
                    currentIndex = index
                } label: {
                    HStack(spacing: 4) {
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Text(question.header?.isEmpty == false ? question.header! : "Q\(index + 1)")
                            .font(FQTheme.fontCaption.weight(.semibold))
                    }
                    .foregroundStyle(isCurrent ? FQTheme.accent : (isDone ? FQTheme.success : FQTheme.textTertiary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (isCurrent ? FQTheme.accent.opacity(0.12) : FQTheme.surfaceSecondary.opacity(0.6)),
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Question \(index + 1): \(question.header ?? "")\(isDone ? ", answered" : "")")
            }
            Spacer()
            Text("\(currentIndex + 1) of \(record.questions.count)")
                .font(FQTheme.fontCaption)
                .foregroundStyle(FQTheme.textTertiary)
        }
    }

    // MARK: - Current question

    @ViewBuilder
    private func carouselQuestion(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: FQTheme.space2) {
            Text(question.question)
                .font(FQTheme.fontBodyMedium)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options, id: \.self) { option in
                    optionRow(question: question, option: option)
                }
                HStack(spacing: 6) {
                    FQTextField(
                        placeholder: "Other — type your own answer…",
                        text: Binding(
                            get: { customAnswers[question.question] ?? "" },
                            set: { customAnswers[question.question] = $0 }
                        ),
                        onSubmit: { advanceOrSubmit(from: question) }
                    )
                }
            }

            HStack {
                if currentIndex > 0 {
                    FQButton(title: "Back", systemImage: "chevron.left", variant: .ghost, size: .small) {
                        currentIndex -= 1
                    }
                }
                Spacer()
                if question.multiSelect || hasCustomAnswer(question) || answer(for: question) != nil {
                    FQButton(
                        title: isLastQuestion ? "Send answers" : "Next",
                        systemImage: isLastQuestion ? "arrow.up" : "chevron.right",
                        variant: .primary,
                        size: .small
                    ) {
                        advanceOrSubmit(from: question)
                    }
                }
            }
        }
    }

    private func optionRow(question: AskQuestion, option: AskQuestionOption) -> some View {
        let selected = selections[question.question]?.contains(option.label) ?? false
        return Button {
            guard isPending else { return }
            var set = selections[question.question] ?? []
            if question.multiSelect {
                if selected { set.remove(option.label) } else { set.insert(option.label) }
                selections[question.question] = set
            } else {
                set = [option.label]
                selections[question.question] = set
                customAnswers[question.question] = nil
                // Terminal-style: picking a single-select answer moves on.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    advanceOrSubmit(from: question)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName(selected: selected, multi: question.multiSelect))
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? FQTheme.accent : FQTheme.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(FQTheme.fontBodyMedium)
                        .foregroundStyle(FQTheme.textPrimary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(FQTheme.fontCaption)
                            .foregroundStyle(FQTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                selected ? FQTheme.accent.opacity(0.08) : FQTheme.surfaceSecondary.opacity(0.5),
                in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                    .strokeBorder(selected ? FQTheme.accent.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.label)\(selected ? ", selected" : "")")
    }

    // MARK: - Answered summary

    private var answeredSummary: some View {
        VStack(alignment: .leading, spacing: FQTheme.space2) {
            ForEach(record.questions) { question in
                HStack(alignment: .top, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        FQBadge(text: header, tone: .accent)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(question.question)
                            .font(FQTheme.fontSmall)
                            .foregroundStyle(FQTheme.textSecondary)
                        if let answer = record.answers[question.question] {
                            Text(answer)
                                .font(FQTheme.fontBodyMedium)
                        }
                    }
                }
            }
            if record.answered {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(FQTheme.success)
                    Text("Answered")
                        .font(FQTheme.fontCaption)
                        .foregroundStyle(FQTheme.textSecondary)
                }
            }
        }
    }

    // MARK: - Flow

    private func iconName(selected: Bool, multi: Bool) -> String {
        if multi {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func hasCustomAnswer(_ question: AskQuestion) -> Bool {
        !(customAnswers[question.question] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func answer(for question: AskQuestion) -> String? {
        let custom = (customAnswers[question.question] ?? "").trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        if let set = selections[question.question], !set.isEmpty {
            return set.sorted().joined(separator: ", ")
        }
        return nil
    }

    private func advanceOrSubmit(from question: AskQuestion) {
        guard answer(for: question) != nil else { return }
        if isLastQuestion {
            submit()
        } else {
            currentIndex += 1
        }
    }

    private func submit() {
        var answers: [String: String] = [:]
        for question in record.questions {
            if let value = answer(for: question) {
                answers[question.question] = value
            }
        }
        guard !answers.isEmpty else { return }
        // If earlier questions were skipped, jump back to the first gap
        // instead of submitting incomplete answers.
        if answers.count < record.questions.count,
           let firstGap = record.questions.firstIndex(where: { answers[$0.question] == nil }) {
            currentIndex = firstGap
            return
        }
        onAnswer(answers)
    }
}

// MARK: - Permission card

/// "Claude wants to run X — Allow / Deny" inline approval.
struct PermissionCard: View {
    let record: PermissionRecord
    let isPending: Bool
    var onDecision: (Bool) -> Void

    var body: some View {
        FQCard(radius: FQTheme.radiusMedium, padding: FQTheme.space3) {
            VStack(alignment: .leading, spacing: FQTheme.space2) {
                HStack(spacing: 7) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(FQTheme.warning)
                    Text("Wants to run ")
                        .font(FQTheme.fontSmall)
                        .foregroundStyle(FQTheme.textSecondary)
                    + Text(record.toolName)
                        .font(FQTheme.fontMono.weight(.semibold))
                    Spacer()
                    decisionBadge
                }
                if !record.summary.isEmpty {
                    Text(record.summary)
                        .font(FQTheme.fontMono)
                        .foregroundStyle(FQTheme.textPrimary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FQTheme.codeBackground, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
                }
                if isPending {
                    HStack(spacing: FQTheme.space2) {
                        Spacer()
                        FQButton(title: "Deny", variant: .destructive, size: .small) {
                            onDecision(false)
                        }
                        FQButton(title: "Allow", systemImage: "checkmark", variant: .primary, size: .small) {
                            onDecision(true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var decisionBadge: some View {
        if let allowed = record.allowed {
            FQBadge(
                text: allowed ? "Allowed" : "Denied",
                tone: allowed ? .success : .danger,
                systemImage: allowed ? "checkmark" : "xmark"
            )
        }
    }
}

// MARK: - Composer (Image 2 layout)

/// The rounded composer card (Astryx-styled): attachment chips above, text
/// area, quiet control row. Typing stays enabled while the agent works —
/// sends queue (Cursor) or stream straight into the session (Claude).
struct AgentChatComposer: View {
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
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FQTheme.space2) {
            if !attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(attachments) { attachment in
                        FQChip(title: attachment.name, systemImage: attachment.isImage ? "photo" : "doc") {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
            }

            if queuedCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5, weight: .medium))
                    Text("\(queuedCount) message\(queuedCount == 1 ? "" : "s") queued — sends when this run finishes")
                        .font(FQTheme.fontCaption)
                }
                .foregroundStyle(FQTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                FQTextArea(placeholder: placeholder, text: $text, minHeight: 38, maxHeight: 120)
                    .focused($focused)
                    .padding(.horizontal, FQTheme.space3)
                    .padding(.top, FQTheme.space2)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .ignored }
                        DispatchQueue.main.async { onSubmit() }
                        return .handled
                    }

                HStack(spacing: 6) {
                    if showsModelPicker {
                        FQMenuChip(title: model.displayName, systemImage: "sparkles") {
                            ForEach([AgentModelOption.auto, .fable, .opus, .sonnet, .haiku]) { option in
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
                    }

                    FQMenuChip(title: permissionPreset.displayName, systemImage: "gearshape") {
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

                    Spacer(minLength: 0)

                    if let onAttach {
                        FQIconButton(systemImage: "paperclip", size: 26, iconSize: 12, help: "Attach files") {
                            onAttach()
                        }
                    }
                    if let onMic {
                        FQIconButton(
                            systemImage: isListening ? "mic.fill" : "mic",
                            size: 26,
                            iconSize: 12,
                            tint: isListening ? FQTheme.danger : nil,
                            help: isListening ? "Stop dictation" : "Dictate"
                        ) {
                            onMic()
                        }
                    }
                    if isBusy, let onStop {
                        FQIconButton(systemImage: "stop.fill", size: 28, iconSize: 10.5, help: "Stop this run") {
                            onStop()
                        }
                    }
                    FQIconButton(
                        systemImage: "arrow.up",
                        size: 28,
                        iconSize: 12.5,
                        filled: true,
                        help: isBusy ? "Send — runs as the next turn" : "Send",
                        isDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        onSubmit()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(FQTheme.surface, in: RoundedRectangle(cornerRadius: FQTheme.radiusLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FQTheme.radiusLarge, style: .continuous)
                    .strokeBorder(focused ? FQTheme.focusRing : FQTheme.border, lineWidth: focused ? 2 : 1)
            )
        }
    }
}
