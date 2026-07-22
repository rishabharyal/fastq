import SwiftUI

/// Standard button. Variants cover every button in the app so restyling
/// is centralized here.
struct FQButton: View {
    enum Variant {
        case primary       // filled, high-emphasis (Send, Allow)
        case secondary     // subtle filled
        case ghost         // borderless text
        case destructive   // red-tinted
        case outline       // bordered
    }

    enum Size {
        case small, regular

        var font: Font { self == .small ? FQTheme.fontSmall : FQTheme.fontBodyMedium }
        var paddingH: CGFloat { self == .small ? 10 : 14 }
        var paddingV: CGFloat { self == .small ? 4 : 7 }
    }

    let title: String
    var systemImage: String?
    var variant: Variant = .secondary
    var size: Size = .regular
    var isLoading = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(size == .small ? .system(size: 10, weight: .semibold) : .system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(size.font.weight(.medium))
            }
            .padding(.horizontal, size.paddingH)
            .padding(.vertical, size.paddingV)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FQTheme.radiusSmall, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: variant == .outline ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(isLoading)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return FQTheme.onControlPrimary
        case .secondary, .outline: return FQTheme.textPrimary
        case .ghost: return FQTheme.textSecondary
        case .destructive: return FQTheme.danger
        }
    }

    private var background: Color {
        switch variant {
        case .primary: return FQTheme.controlPrimary.opacity(isHovering ? 0.88 : 1)
        case .secondary: return isHovering ? FQTheme.surfaceHover : FQTheme.surfaceSecondary
        case .ghost: return isHovering ? FQTheme.surfaceSecondary : .clear
        case .destructive: return FQTheme.danger.opacity(isHovering ? 0.18 : 0.12)
        case .outline: return isHovering ? FQTheme.surfaceSecondary : .clear
        }
    }

    private var borderColor: Color {
        variant == .outline ? FQTheme.border : .clear
    }
}

/// Icon-only circular/rounded button (mic, attach, close…).
struct FQIconButton: View {
    let systemImage: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 13
    /// Filled circle style (the send button).
    var filled = false
    var tint: Color? = nil
    var help = ""
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(backgroundColor, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .help(help)
        .accessibilityLabel(help.isEmpty ? systemImage : help)
    }

    private var iconColor: Color {
        if filled { return FQTheme.onControlPrimary }
        return tint ?? FQTheme.textSecondary
    }

    private var backgroundColor: Color {
        if filled { return FQTheme.controlPrimary.opacity(isHovering ? 0.88 : 1) }
        return isHovering ? FQTheme.surfaceSecondary : .clear
    }
}
