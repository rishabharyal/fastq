import SwiftUI
import AppKit

/// Lightweight native markdown renderer: paragraphs with inline styling,
/// bullet/numbered lists, and fenced code blocks with a copy button.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: FQTheme.space2) {
            ForEach(Array(Self.segments(from: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .prose(let prose):
                    proseView(prose)
                }
            }
        }
    }

    @ViewBuilder
    private func proseView(_ prose: String) -> some View {
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer().frame(height: 2)
                } else if let bullet = Self.bulletContent(trimmed) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(FQTheme.fontBody)
                            .foregroundStyle(FQTheme.textSecondary)
                        inline(bullet)
                    }
                    .padding(.leading, 4)
                } else if let (number, content) = Self.numberedContent(trimmed) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(number).")
                            .font(FQTheme.fontBody)
                            .foregroundStyle(FQTheme.textSecondary)
                        inline(content)
                    }
                    .padding(.leading, 4)
                } else if let heading = Self.headingContent(trimmed) {
                    Text(heading)
                        .font(.system(size: 13.5, weight: .semibold))
                        .padding(.top, 3)
                } else {
                    inline(line)
                }
            }
        }
    }

    private func inline(_ string: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
        return Text(styledInlineCode(attributed))
            .font(FQTheme.fontBody)
            .foregroundStyle(FQTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .lineSpacing(2.5)
    }

    /// Give `inline code` runs a monospaced font + subtle background.
    private func styledInlineCode(_ attributed: AttributedString) -> AttributedString {
        var result = attributed
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            result[run.range].font = FQTheme.fontMono
            result[run.range].backgroundColor = FQTheme.surfaceSecondary
        }
        return result
    }

    // MARK: - Parsing

    enum Segment {
        case prose(String)
        case code(String, language: String?)
    }

    static func segments(from text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    segments.append(.code(code.joined(separator: "\n"), language: language))
                    code = []
                    inCode = false
                } else {
                    let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { segments.append(.prose(joined)) }
                    prose = []
                    language = trimmed.count > 3 ? String(trimmed.dropFirst(3)) : nil
                    inCode = true
                }
            } else if inCode {
                code.append(String(line))
            } else {
                prose.append(String(line))
            }
        }
        if inCode, !code.isEmpty {
            segments.append(.code(code.joined(separator: "\n"), language: language))
        }
        let rest = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { segments.append(.prose(rest)) }
        return segments
    }

    static func bulletContent(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    static func numberedContent(_ line: String) -> (Int, String)? {
        guard let dot = line.firstIndex(of: "."),
              let number = Int(line[line.startIndex..<dot]),
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " " else {
            return nil
        }
        return (number, String(line[line.index(dot, offsetBy: 2)...]))
    }

    static func headingContent(_ line: String) -> String? {
        for prefix in ["#### ", "### ", "## ", "# "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }
}

/// Fenced code block: header row (filename/language + copy), monospaced body.
struct CodeBlockView: View {
    let code: String
    var language: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(FQTheme.fontCaption)
                    .foregroundStyle(FQTheme.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? FQTheme.success : FQTheme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(FQTheme.fontMono)
                    .foregroundStyle(FQTheme.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(FQTheme.codeBackground, in: RoundedRectangle(cornerRadius: FQTheme.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FQTheme.radiusMedium, style: .continuous)
                .strokeBorder(FQTheme.border, lineWidth: 1)
        )
    }
}
