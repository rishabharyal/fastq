import SwiftUI

/// Elevated surface card (composer, question/permission cards, code blocks).
struct FQCard<Content: View>: View {
    var radius: CGFloat = FQTheme.radiusMedium
    var padding: CGFloat = FQTheme.space3
    var background: Color = FQTheme.surface
    var bordered = true
    var shadowed = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(bordered ? FQTheme.border : .clear, lineWidth: 1)
            )
            .shadow(color: shadowed ? .black.opacity(0.08) : .clear, radius: 10, y: 3)
    }
}

/// Section label in caps (COMMENTS, TOOLS…).
struct FQSectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(FQTheme.textSecondary)
    }
}

/// Centered horizontal divider with a label ("Today").
struct FQLabeledDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: FQTheme.space3) {
            Rectangle().fill(FQTheme.border).frame(height: 1)
            Text(text)
                .font(FQTheme.fontCaption.weight(.medium))
                .foregroundStyle(FQTheme.textTertiary)
                .fixedSize()
            Rectangle().fill(FQTheme.border).frame(height: 1)
        }
    }
}
