import SwiftUI

/// Removable pill chip — attachment files above the composer, filters, etc.
struct FQChip: View {
    let title: String
    var systemImage: String?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(FQTheme.textSecondary)
            }
            Text(title)
                .font(FQTheme.fontSmall.weight(.medium))
                .foregroundStyle(FQTheme.textPrimary)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(FQTheme.textSecondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(FQTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
    }
}

/// Dropdown chip — the composer's model / settings selectors (label + chevron).
struct FQMenuChip<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var menuContent: Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(FQTheme.fontBodyMedium)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(FQTheme.textTertiary)
            }
            .foregroundStyle(FQTheme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isHovering ? FQTheme.surfaceSecondary : .clear,
                in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
    }
}

/// Astryx-style tinted status pill ("Low", "High", "Task 4821") — solid
/// hue background with matching readable text.
struct FQStatusPill: View {
    let text: String
    var hue: FQHue = .gray

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(hue.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(hue.background, in: Capsule())
    }
}

/// Small status badge (Running, Waiting, Done, session cost).
struct FQBadge: View {
    enum Tone { case neutral, success, warning, danger, accent }

    let text: String
    var tone: Tone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .font(FQTheme.fontCaption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .neutral: return FQTheme.textSecondary
        case .success: return FQTheme.success
        case .warning: return FQTheme.warning
        case .danger: return FQTheme.danger
        case .accent: return FQTheme.accent
        }
    }
}
