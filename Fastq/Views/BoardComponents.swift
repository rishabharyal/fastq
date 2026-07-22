import SwiftUI
import AppKit

// MARK: - Priority

/// The backend's `tasks.priority` enum: low | medium | high | urgent (nullable).
enum TaskPriority: String, CaseIterable, Identifiable {
    case low, medium, high, urgent

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// Astryx status hue (matches the board pill design: Low mint,
    /// Medium yellow, High/Urgent red).
    var hue: FQHue {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        case .urgent: return .purple
        }
    }

    var color: Color { hue.text }

    var systemImage: String {
        switch self {
        case .low: return "chevron.down"
        case .medium: return "equal"
        case .high: return "chevron.up"
        case .urgent: return "exclamationmark.2"
        }
    }
}

extension FastplayTask {
    var priorityValue: TaskPriority? {
        guard let priority else { return nil }
        return TaskPriority(rawValue: priority.lowercased())
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority
    var compact = false

    var body: some View {
        FQStatusPill(text: priority.displayName, hue: priority.hue)
            .help("Priority: \(priority.displayName)")
            .accessibilityLabel("Priority \(priority.displayName)")
    }
}

extension FastplayTask {
    /// Short display code ("Task 4F2A") derived from the UUID.
    var shortCode: String {
        let hex = id.replacingOccurrences(of: "-", with: "").uppercased()
        return "Task \(String(hex.prefix(4)))"
    }
}

// MARK: - Labels

extension Color {
    /// `#RGB` / `#RRGGBB` → Color; falls back to secondary gray.
    init(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else {
            self = .secondary
            return
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            self = .secondary
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct LabelChipView: View {
    let label: FastplayLabel
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hexString: label.color))
                .frame(width: 6, height: 6)
            Text(label.name)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(hexString: label.color).opacity(0.14), in: Capsule())
    }
}

/// Preset colors offered when creating a new label inline.
enum LabelColorPalette {
    static let all = [
        "#EF476F", "#F78C6B", "#FFD166", "#06D6A0",
        "#118AB2", "#7B68EE", "#8D99AE", "#43AA8B",
    ]
}

// MARK: - Dates

struct DueDateBadge: View {
    let dueDate: String?
    var completed = false

    var body: some View {
        if let date = FastplayDates.parse(dueDate) {
            let overdue = !completed && date < Calendar.current.startOfDay(for: Date())
            HStack(spacing: 3) {
                Image(systemName: overdue ? "calendar.badge.exclamationmark" : "calendar")
                    .font(.system(size: 9, weight: .semibold))
                Text(Self.shortDay(date))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(overdue ? Color.red : Color.secondary)
            .help(overdue ? "Overdue" : "Due date")
        }
    }

    private static func shortDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }
}

// MARK: - People

struct AvatarBubble: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(backgroundColor, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            .help(name)
            .accessibilityLabel(name)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let chars = parts.compactMap(\.first).map(String.init).joined()
        return chars.isEmpty ? "?" : chars.uppercased()
    }

    /// Stable hue per name so the same person always gets the same color.
    private var backgroundColor: Color {
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) }
        let hue = Double(abs(hash) % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }
}

struct AvatarStack: View {
    let users: [FastplayUser]
    var size: CGFloat = 20
    var maxShown = 3

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(users.prefix(maxShown)) { user in
                AvatarBubble(name: user.name.isEmpty ? user.email : user.name, size: size)
            }
            if users.count > maxShown {
                Text("+\(users.count - maxShown)")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
        }
    }
}

// MARK: - Counts

struct MetaCountBadge: View {
    let systemImage: String
    let count: Int
    var help = ""

    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.secondary)
            .help(help)
        }
    }
}

// MARK: - Flow layout

/// Left-aligned wrapping row — used for label chips and assignee chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in computeRows(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width = current.indices.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Pasteboard files

/// Reads file URLs (or a temp PNG for raw image data / screenshots) from
/// the general pasteboard so ⌘V can attach files anywhere.
enum PasteboardFiles {
    static func read() -> [URL] {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            return urls
        }
        var data: Data?
        if let png = pb.data(forType: .png) {
            data = png
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data else { return [] }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-paste-\(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: url)
            return [url]
        } catch {
            return []
        }
    }
}

// MARK: - Mentions

/// The backend's rich-mention markup (parsed by MentionParser server-side):
///   @[Display Name](user:UUID)  — mentions a workspace member
///   #[Task title](task:UUID)    — references another task
enum MentionMarkup {
    static func user(_ user: FastplayUser) -> String {
        "@[\(user.name.isEmpty ? user.email : user.name)](user:\(user.id))"
    }

    static func task(_ task: FastplayTask) -> String {
        "#[\(task.title)](task:\(task.id))"
    }

    /// Pretty display: markup → accent-colored "@Name" / "#Title".
    static func styled(_ raw: String) -> AttributedString {
        var result = AttributedString()
        let ns = raw as NSString
        let pattern = try! NSRegularExpression(pattern: "([@#])\\[([^\\]]*)\\]\\((?:user|task):[^)]+\\)")
        var cursor = 0
        for match in pattern.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let sigil = ns.substring(with: match.range(at: 1))
            let label = ns.substring(with: match.range(at: 2))
            var chip = AttributedString("\(sigil)\(label)")
            chip.foregroundColor = FQTheme.accent
            chip.font = FQTheme.fontBodyMedium
            result += chip
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(from: cursor))
        }
        return result
    }
}

/// Text input with @user / #task mention autocomplete. Typing a trailing
/// `@query` or `#query` opens inline suggestions; picking one inserts the
/// backend's id-carrying markup.
struct MentionTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var workspaceID: String?
    var projectID: String?
    /// Compact = single growing text field (comment input) instead of a box.
    var compact = false
    var minHeight: CGFloat = 64
    var maxHeight: CGFloat = 120
    var onSubmit: (() -> Void)?

    private enum Kind { case user, task }
    private enum Suggestion: Identifiable {
        case user(FastplayUser)
        case task(FastplayTask)

        var id: String {
            switch self {
            case .user(let u): return "u-\(u.id)"
            case .task(let t): return "t-\(t.id)"
            }
        }
    }

    @State private var activeKind: Kind?
    @State private var suggestions: [Suggestion] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            editor
                .onChange(of: text) { _, newValue in
                    detectMention(in: newValue)
                }
            if !suggestions.isEmpty {
                suggestionList
            }
            Text("@ mention people · # reference tasks")
                .font(.system(size: 9.5))
                .foregroundStyle(FQTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if compact {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(FQTheme.fontBody)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(FQTheme.surface, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                        .strokeBorder(FQTheme.border, lineWidth: 1)
                )
                .onSubmit { onSubmit?() }
        } else {
            TextEditor(text: $text)
                .font(FQTheme.fontBody)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .padding(6)
                .background(FQTheme.surface, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                        .strokeBorder(FQTheme.border, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(FQTheme.fontBody)
                            .foregroundStyle(FQTheme.textTertiary)
                            .padding(.top, 6)
                            .padding(.leading, 11)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(suggestions.prefix(5)) { suggestion in
                Button {
                    insert(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        switch suggestion {
                        case .user(let user):
                            AvatarBubble(name: user.name.isEmpty ? user.email : user.name, size: 18)
                            Text(user.name.isEmpty ? user.email : user.name)
                                .font(FQTheme.fontBodyMedium)
                            Text(user.email)
                                .font(FQTheme.fontCaption)
                                .foregroundStyle(FQTheme.textSecondary)
                        case .task(let task):
                            Image(systemName: "number")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(FQTheme.accent)
                            Text(task.title)
                                .font(FQTheme.fontBodyMedium)
                                .lineLimit(1)
                            if let column = task.resolvedColumnName {
                                Text(column)
                                    .font(FQTheme.fontCaption)
                                    .foregroundStyle(FQTheme.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(FQTheme.surfaceSecondary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxWidth: 360)
    }

    /// A mention trigger is a trailing `@word` / `#word` (no completed
    /// markup) at the end of the text.
    private func detectMention(in newValue: String) {
        guard let lastToken = newValue
            .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace || $0.isNewline })
            .last.map(String.init),
              newValue.last.map({ !$0.isWhitespace && !$0.isNewline }) == true else {
            clearSuggestions()
            return
        }
        let kind: Kind
        if lastToken.hasPrefix("@"), !lastToken.contains("](") {
            kind = .user
        } else if lastToken.hasPrefix("#"), !lastToken.contains("](") {
            kind = .task
        } else {
            clearSuggestions()
            return
        }
        let query = String(lastToken.dropFirst())
        activeKind = kind
        searchTask?.cancel()
        let workspaceID = workspaceID
        let projectID = projectID
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            switch kind {
            case .user:
                let users = (try? await FastplayAPIClient.shared.searchUsers(
                    query: query.isEmpty ? nil : query,
                    workspaceID: workspaceID
                )) ?? []
                guard !Task.isCancelled else { return }
                suggestions = users.map { .user($0) }
            case .task:
                let tasks = (try? await FastplayAPIClient.shared.listTasks(
                    query: query.isEmpty ? nil : query,
                    workspaceID: workspaceID,
                    projectID: projectID,
                    perPage: 8
                )) ?? []
                guard !Task.isCancelled else { return }
                suggestions = tasks.map { .task($0) }
            }
        }
    }

    private func insert(_ suggestion: Suggestion) {
        // Replace the trailing "@query"/"#query" token with markup.
        var working = text
        if let tokenStart = trailingTokenStart(in: working) {
            working = String(working[working.startIndex..<tokenStart])
        }
        switch suggestion {
        case .user(let user):
            working += MentionMarkup.user(user) + " "
        case .task(let task):
            working += MentionMarkup.task(task) + " "
        }
        text = working
        clearSuggestions()
    }

    private func trailingTokenStart(in value: String) -> String.Index? {
        var index = value.endIndex
        while index > value.startIndex {
            let previous = value.index(before: index)
            if value[previous].isWhitespace || value[previous].isNewline {
                break
            }
            index = previous
        }
        return index < value.endIndex ? index : nil
    }

    private func clearSuggestions() {
        searchTask?.cancel()
        activeKind = nil
        if !suggestions.isEmpty {
            suggestions = []
        }
    }
}

// MARK: - Column tint

/// Column color from the API when set; sensible defaults for the stock
/// Todo / In Progress / Done columns otherwise.
func boardColumnTint(_ column: FastplayColumn) -> Color {
    if let hex = column.color, !hex.isEmpty {
        return Color(hexString: hex)
    }
    switch column.name.lowercased() {
    case "todo", "to do", "backlog": return Color.secondary
    case "in progress", "in_progress", "doing": return Color.accentColor
    case "done", "completed": return Color.green
    default: return Color.purple.opacity(0.8)
    }
}
