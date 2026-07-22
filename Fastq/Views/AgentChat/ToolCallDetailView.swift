import SwiftUI
import AppKit

// MARK: - Diff model

/// One rendered row of a unified diff.
struct ToolDiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case context, added, removed
        /// "⋯ N unchanged lines" separator between hunks.
        case gap
    }

    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

/// Line-based unified diff. Deliberately self-contained (no shelling out)
/// and bounded: huge inputs degrade to a whole-block replacement rather
/// than stalling the transcript.
enum ToolDiff {
    /// Above this the LCS table is too big to be worth building.
    private static let lcsCellBudget = 400_000
    /// Unchanged lines kept on each side of a change.
    private static let contextLines = 3

    static func lines(old: String, new: String, maxRendered: Int = 600) -> [ToolDiffLine] {
        let oldLines = split(old)
        let newLines = split(new)

        // 1. Peel identical head/tail so the expensive part stays small.
        var head = 0
        while head < oldLines.count, head < newLines.count, oldLines[head] == newLines[head] {
            head += 1
        }
        var tail = 0
        while tail < oldLines.count - head,
              tail < newLines.count - head,
              oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] {
            tail += 1
        }

        let oldMiddle = Array(oldLines[head..<(oldLines.count - tail)])
        let newMiddle = Array(newLines[head..<(newLines.count - tail)])

        var ops: [(kind: ToolDiffLine.Kind, text: String)] = []
        for line in oldLines.prefix(head) { ops.append((.context, line)) }
        ops.append(contentsOf: middleOps(oldMiddle, newMiddle))
        for line in oldLines.suffix(tail) { ops.append((.context, line)) }

        return render(ops, maxRendered: maxRendered)
    }

    // MARK: Core

    private static func middleOps(
        _ oldLines: [String],
        _ newLines: [String]
    ) -> [(kind: ToolDiffLine.Kind, text: String)] {
        if oldLines.isEmpty {
            return newLines.map { (.added, $0) }
        }
        if newLines.isEmpty {
            return oldLines.map { (.removed, $0) }
        }
        guard oldLines.count * newLines.count <= lcsCellBudget else {
            // Too large to align precisely — show it as a block replacement.
            return oldLines.map { (.removed, $0) } + newLines.map { (.added, $0) }
        }

        // Classic LCS table, walked back into a unified edit script.
        let n = oldLines.count
        let m = newLines.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = oldLines[i] == newLines[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var ops: [(kind: ToolDiffLine.Kind, text: String)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if oldLines[i] == newLines[j] {
                ops.append((.context, oldLines[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append((.removed, oldLines[i]))
                i += 1
            } else {
                ops.append((.added, newLines[j]))
                j += 1
            }
        }
        while i < n {
            ops.append((.removed, oldLines[i]))
            i += 1
        }
        while j < m {
            ops.append((.added, newLines[j]))
            j += 1
        }
        return ops
    }

    /// Numbers the ops and collapses long unchanged stretches into gaps.
    private static func render(
        _ ops: [(kind: ToolDiffLine.Kind, text: String)],
        maxRendered: Int
    ) -> [ToolDiffLine] {
        // Which context rows sit close enough to a change to be worth showing.
        var keep = [Bool](repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() where op.kind != .context {
            let lower = max(0, index - contextLines)
            let upper = min(ops.count - 1, index + contextLines)
            for k in lower...upper { keep[k] = true }
        }
        // A pure-context diff (identical strings) still deserves a preview.
        if !keep.contains(true) {
            for index in 0..<min(ops.count, contextLines * 2) { keep[index] = true }
        }

        var lines: [ToolDiffLine] = []
        var oldNumber = 0
        var newNumber = 0
        var skipped = 0
        var nextID = 0

        func flushGap() {
            guard skipped > 0 else { return }
            lines.append(ToolDiffLine(
                id: nextID,
                kind: .gap,
                oldNumber: nil,
                newNumber: nil,
                text: "\(skipped) unchanged line\(skipped == 1 ? "" : "s")"
            ))
            nextID += 1
            skipped = 0
        }

        for (index, op) in ops.enumerated() {
            switch op.kind {
            case .context:
                oldNumber += 1
                newNumber += 1
            case .removed:
                oldNumber += 1
            case .added:
                newNumber += 1
            case .gap:
                continue
            }
            guard keep[index] else {
                skipped += 1
                continue
            }
            flushGap()
            guard lines.count < maxRendered else {
                lines.append(ToolDiffLine(
                    id: nextID,
                    kind: .gap,
                    oldNumber: nil,
                    newNumber: nil,
                    text: "diff truncated"
                ))
                return lines
            }
            lines.append(ToolDiffLine(
                id: nextID,
                kind: op.kind,
                oldNumber: op.kind == .added ? nil : oldNumber,
                newNumber: op.kind == .removed ? nil : newNumber,
                text: op.text
            ))
            nextID += 1
        }
        flushGap()
        return lines
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        // A trailing newline shouldn't render as a phantom empty line.
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// Diffs are computed on first expand and kept keyed by tool-call id so
/// collapsing/re-expanding (or scrolling a row out and back) is free.
@MainActor
final class ToolDiffCache {
    static let shared = ToolDiffCache()

    private var storage: [String: [ToolDiffLine]] = [:]
    private var order: [String] = []
    private let limit = 120

    func lines(for key: String, old: String, new: String) -> [ToolDiffLine] {
        if let cached = storage[key] { return cached }
        let computed = ToolDiff.lines(old: old, new: new)
        storage[key] = computed
        order.append(key)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            storage[oldest] = nil
        }
        return computed
    }
}

// MARK: - Detail view

/// Expanded body of a tool call row: the real diff, file contents, command
/// output — whatever the tool actually did.
struct ToolCallDetailView: View {
    let call: ToolCallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: FQTheme.space2) {
            switch call.detailKind {
            case .edit: editBody
            case .write: writeBody
            case .bash: bashBody
            case .read, .search: lookupBody
            case .other: otherBody
            }
            resultSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FQTheme.space2)
        .background(
            FQTheme.surface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                .strokeBorder(FQTheme.border, lineWidth: 1)
        )
    }

    // MARK: Per-kind bodies

    @ViewBuilder
    private var editBody: some View {
        pathHeader
        if let patches = call.edits, !patches.isEmpty {
            ForEach(Array(patches.enumerated()), id: \.offset) { index, patch in
                ToolDetailSection(
                    title: patches.count > 1 ? "Edit \(index + 1) of \(patches.count)" : "Diff",
                    copyText: patch.newString
                ) {
                    ToolDiffBlock(
                        cacheKey: "\(call.id)#\(index)",
                        old: patch.oldString,
                        new: patch.newString
                    )
                }
            }
        } else if call.oldString != nil || call.newString != nil {
            ToolDetailSection(title: "Diff", copyText: call.newString) {
                ToolDiffBlock(
                    cacheKey: call.id,
                    old: call.oldString ?? "",
                    new: call.newString ?? ""
                )
            }
        } else if let raw = call.rawInput {
            ToolDetailSection(title: "Input", copyText: raw) {
                ToolCodeBlock(text: raw)
            }
        }
    }

    @ViewBuilder
    private var writeBody: some View {
        pathHeader
        if let content = call.content {
            ToolDetailSection(title: "Contents", copyText: content) {
                ToolCodeBlock(text: content, numbered: true)
            }
        } else if let raw = call.rawInput {
            ToolDetailSection(title: "Input", copyText: raw) {
                ToolCodeBlock(text: raw)
            }
        }
    }

    @ViewBuilder
    private var bashBody: some View {
        if let command = call.command {
            ToolDetailSection(title: "Command", copyText: command) {
                ToolCodeBlock(text: command, prompt: "$", maxLines: 12)
            }
        } else if let raw = call.rawInput {
            ToolDetailSection(title: "Input", copyText: raw) {
                ToolCodeBlock(text: raw)
            }
        }
    }

    @ViewBuilder
    private var lookupBody: some View {
        pathHeader
        if let pattern = call.pattern {
            ToolDetailSection(title: "Pattern", copyText: pattern) {
                ToolCodeBlock(text: pattern, maxLines: 6)
            }
        }
        if call.pattern == nil, call.filePath == nil, let raw = call.rawInput {
            ToolDetailSection(title: "Input", copyText: raw) {
                ToolCodeBlock(text: raw)
            }
        }
    }

    @ViewBuilder
    private var otherBody: some View {
        pathHeader
        if let raw = call.rawInput {
            ToolDetailSection(title: "Input", copyText: raw) {
                ToolCodeBlock(text: raw)
            }
        } else if let command = call.command {
            ToolDetailSection(title: "Command", copyText: command) {
                ToolCodeBlock(text: command, prompt: "$", maxLines: 12)
            }
        }
    }

    // MARK: Shared pieces

    @ViewBuilder
    private var pathHeader: some View {
        if let path = call.filePath ?? call.searchPath {
            HStack(spacing: 6) {
                Image(systemName: call.detailKind == .search ? "folder" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(FQTheme.textTertiary)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(FQTheme.fontMono)
                    .foregroundStyle(FQTheme.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                ToolCopyButton(text: path, label: "Copy path")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Path \(path)")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result = call.resultText, !result.isEmpty {
            ToolDetailSection(
                title: call.ok == false ? "Error" : "Output",
                tone: call.ok == false ? FQTheme.danger : nil,
                copyText: result
            ) {
                ToolCodeBlock(
                    text: result,
                    tint: call.ok == false ? FQTheme.danger : nil
                )
            }
        }
    }
}

// MARK: - Section shell

/// Labelled block with a copy affordance in its header.
struct ToolDetailSection<Content: View>: View {
    let title: String
    var tone: Color?
    var copyText: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(tone ?? FQTheme.textTertiary)
                Spacer(minLength: 0)
                if let copyText, !copyText.isEmpty {
                    ToolCopyButton(text: copyText, label: "Copy \(title.lowercased())")
                }
            }
            content
        }
    }
}

// MARK: - Code block

/// Monospaced block: vertically capped with a "show more" toggle,
/// horizontally scrollable on its own so the transcript never moves.
struct ToolCodeBlock: View {
    let text: String
    var numbered = false
    /// Rendered before every line ("$" for shell commands).
    var prompt: String?
    var maxLines = 18
    var tint: Color?

    @State private var expanded = false

    /// Hard ceiling regardless of "show more" — nothing pathological renders.
    private let ceiling = 600

    private var allLines: [String] {
        text.components(separatedBy: "\n")
    }

    private var visibleLines: [String] {
        let lines = allLines
        let limit = expanded ? ceiling : maxLines
        return Array(lines.prefix(limit))
    }

    private var hiddenCount: Int {
        max(0, allLines.count - visibleLines.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            if numbered {
                                Text("\(index + 1)")
                                    .font(FQTheme.fontMono)
                                    .foregroundStyle(FQTheme.textTertiary)
                                    .frame(width: 30, alignment: .trailing)
                            } else if let prompt {
                                Text(prompt)
                                    .font(FQTheme.fontMono)
                                    .foregroundStyle(FQTheme.textTertiary)
                            }
                            Text(line.isEmpty ? " " : line)
                                .font(FQTheme.fontMono)
                                .foregroundStyle(tint ?? FQTheme.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .padding(FQTheme.space2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FQTheme.codeBackground,
                in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
            )

            if hiddenCount > 0 || expanded {
                ToolShowMoreButton(expanded: $expanded, hiddenCount: hiddenCount)
            }
        }
    }
}

// MARK: - Diff block

/// Line-numbered unified diff, computed lazily and cached by call id.
struct ToolDiffBlock: View {
    let cacheKey: String
    let old: String
    let new: String
    var maxLines = 24

    @State private var lines: [ToolDiffLine] = []
    @State private var expanded = false

    private var visible: [ToolDiffLine] {
        expanded ? lines : Array(lines.prefix(maxLines))
    }

    private var hiddenCount: Int {
        max(0, lines.count - visible.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { line in
                        row(line)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FQTheme.codeBackground,
                in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
            )

            HStack(spacing: FQTheme.space2) {
                FQBadge(text: "+\(addedCount)", tone: .success)
                FQBadge(text: "−\(removedCount)", tone: .danger)
                Spacer(minLength: 0)
                if hiddenCount > 0 || expanded {
                    ToolShowMoreButton(expanded: $expanded, hiddenCount: hiddenCount)
                }
            }
        }
        .onAppear {
            // Lazy: nothing is diffed until the row is actually expanded.
            guard lines.isEmpty else { return }
            lines = ToolDiffCache.shared.lines(for: cacheKey, old: old, new: new)
        }
        .accessibilityLabel("Diff, \(addedCount) added, \(removedCount) removed lines")
    }

    private var addedCount: Int { lines.filter { $0.kind == .added }.count }
    private var removedCount: Int { lines.filter { $0.kind == .removed }.count }

    @ViewBuilder
    private func row(_ line: ToolDiffLine) -> some View {
        if line.kind == .gap {
            HStack(spacing: 6) {
                Text("⋯")
                    .font(FQTheme.fontMono)
                Text(line.text)
                    .font(FQTheme.fontCaption)
            }
            .foregroundStyle(FQTheme.textTertiary)
            .padding(.horizontal, FQTheme.space2)
            .padding(.vertical, 2)
        } else {
            HStack(alignment: .top, spacing: 0) {
                gutter(line.oldNumber)
                gutter(line.newNumber)
                Text(marker(line.kind))
                    .font(FQTheme.fontMono)
                    .foregroundStyle(color(line.kind) ?? FQTheme.textTertiary)
                    .frame(width: 14, alignment: .center)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(FQTheme.fontMono)
                    .foregroundStyle(color(line.kind) ?? FQTheme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, FQTheme.space2)
            }
            .padding(.vertical, 1)
            .background(background(line.kind))
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? " ")
            .font(FQTheme.fontMono)
            .foregroundStyle(FQTheme.textTertiary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func marker(_ kind: ToolDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private func color(_ kind: ToolDiffLine.Kind) -> Color? {
        switch kind {
        case .added: return FQTheme.success
        case .removed: return FQTheme.danger
        default: return nil
        }
    }

    private func background(_ kind: ToolDiffLine.Kind) -> Color {
        switch kind {
        case .added: return FQTheme.success.opacity(0.12)
        case .removed: return FQTheme.danger.opacity(0.12)
        default: return .clear
        }
    }
}

// MARK: - Small controls

struct ToolShowMoreButton: View {
    @Binding var expanded: Bool
    let hiddenCount: Int

    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                Text(expanded ? "Show less" : "Show \(hiddenCount) more line\(hiddenCount == 1 ? "" : "s")")
                    .font(FQTheme.fontCaption.weight(.medium))
            }
            .foregroundStyle(isHovering ? FQTheme.textPrimary : FQTheme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                isHovering ? FQTheme.surfaceSecondary : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(expanded ? "Show less" : "Show \(hiddenCount) more lines")
    }
}

struct ToolCopyButton: View {
    let text: String
    var label = "Copy"

    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(.easeOut(duration: 0.12)) { copied = false }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(FQTheme.fontCaption.weight(.medium))
            }
            .foregroundStyle(copied ? FQTheme.success : (isHovering ? FQTheme.textPrimary : FQTheme.textTertiary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isHovering && !copied ? FQTheme.surfaceSecondary : .clear,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
