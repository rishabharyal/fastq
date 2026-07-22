import SwiftUI
import AppKit

/// Semantic design tokens — exact values from the Astryx neutral theme
/// (@astryxdesign/theme-neutral). Every component reads from here so a
/// future restyle is one-file work.
enum FQTheme {
    // MARK: - Colors (light / dark adaptive, from theme.css light-dark())

    /// Page body — `--color-background-body`.
    static let background = adaptive(light: hex(0xF1F1F1), dark: hex(0x1B1B1B))
    /// Cards, inputs, elevated surfaces — `--color-background-surface`.
    static let surface = adaptive(light: hex(0xFFFFFF), dark: hex(0x262626))
    /// Subtle neutral fill — `--color-neutral` (#0000000F / #FFFFFF1A).
    static let surfaceSecondary = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.10))
    /// Hovered variant of the neutral fill.
    static let surfaceHover = adaptive(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.15))
    /// Code block background — `--color-syntax-background`.
    static let codeBackground = adaptive(light: hex(0xFAFAFA), dark: hex(0x0A0A0A))
    /// Hairline borders — `--color-border`.
    static let border = adaptive(light: hex(0xEBEBEB), dark: NSColor(white: 1, alpha: 0.10))
    /// Emphasized borders — `--color-border-emphasized`.
    static let borderEmphasized = adaptive(light: hex(0xD4D4D4), dark: hex(0x525252))
    /// `--color-text-primary`.
    static let textPrimary = adaptive(light: hex(0x171717), dark: hex(0xFAFAFA))
    /// `--color-text-secondary`.
    static let textSecondary = adaptive(light: hex(0x737373), dark: hex(0xA3A3A3))
    /// `--color-text-disabled`.
    static let textTertiary = adaptive(light: hex(0xA3A3A3), dark: hex(0x525252))
    /// Filled primary controls — `--color-accent` (monochrome in neutral).
    static let controlPrimary = adaptive(light: hex(0x262626), dark: hex(0xEBEBEB))
    /// `--color-on-accent`.
    static let onControlPrimary = adaptive(light: hex(0xFFFFFF), dark: hex(0x171717))
    /// Interactive accent (links, focus) — follows the app accent (#0074E2).
    static let accent = Color.accentColor
    /// Focus ring — `--shadow-inset-hover` blue at 30%.
    static let focusRing = adaptive(light: hex(0x0074E2, alpha: 0.45), dark: hex(0x82B4FF, alpha: 0.55))
    static let success = adaptive(light: hex(0x198100), dark: hex(0x69AD67))
    static let danger = adaptive(light: hex(0xE33F4A), dark: hex(0xFF6F6C))
    static let warning = adaptive(light: hex(0xC0990E), dark: hex(0xEEC12F))

    // MARK: - Shape (Astryx radius scale)

    /// `--radius-inner` (6) — chips, small controls.
    static let radiusSmall: CGFloat = 6
    /// `--radius-element` (10) — buttons, inputs, cards.
    static let radiusMedium: CGFloat = 10
    /// Between `--radius-container` (12) and `--radius-page` — bubbles, composer.
    static let radiusLarge: CGFloat = 16

    // MARK: - Spacing scale (4pt base)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24

    // MARK: - Typography (Astryx text scale; base 14 ≈ 13pt AppKit)

    static let fontBody = Font.system(size: 13)
    static let fontBodyMedium = Font.system(size: 13, weight: .medium)
    static let fontSmall = Font.system(size: 11.5)
    static let fontCaption = Font.system(size: 10.5)
    static let fontMono = Font.system(size: 12, design: .monospaced)
    static let fontTitle = Font.system(size: 15, weight: .semibold)

    // MARK: - Helpers

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Astryx status hues: tinted background + readable text pairs
/// (`--color-background-X` / `--color-text-X`). Dark backgrounds carry the
/// theme's 24% alpha.
enum FQHue {
    case red, orange, yellow, green, teal, blue, purple, gray

    var background: Color {
        switch self {
        case .red: return FQTheme.adaptive(light: FQTheme.hex(0xFACECB), dark: FQTheme.hex(0xFF9E97, alpha: 0.24))
        case .orange: return FQTheme.adaptive(light: FQTheme.hex(0xFAD0B5), dark: FQTheme.hex(0xFFA258, alpha: 0.24))
        case .yellow: return FQTheme.adaptive(light: FQTheme.hex(0xF8DA9D), dark: FQTheme.hex(0xDEB433, alpha: 0.24))
        case .green: return FQTheme.adaptive(light: FQTheme.hex(0xC5E5C0), dark: FQTheme.hex(0x84C980, alpha: 0.24))
        case .teal: return FQTheme.adaptive(light: FQTheme.hex(0xA5E3D6), dark: FQTheme.hex(0x7EC6B8, alpha: 0.24))
        case .blue: return FQTheme.adaptive(light: FQTheme.hex(0xC4DDFB), dark: FQTheme.hex(0x9EB7FF, alpha: 0.24))
        case .purple: return FQTheme.adaptive(light: FQTheme.hex(0xECCEF3), dark: FQTheme.hex(0xF297FF, alpha: 0.24))
        case .gray: return FQTheme.adaptive(light: FQTheme.hex(0xE5E5E5), dark: NSColor(white: 1, alpha: 0.10))
        }
    }

    var text: Color {
        switch self {
        case .red: return FQTheme.adaptive(light: FQTheme.hex(0x89001A), dark: FQTheme.hex(0xFFC6C1))
        case .orange: return FQTheme.adaptive(light: FQTheme.hex(0x6E3500), dark: FQTheme.hex(0xFFC9A2))
        case .yellow: return FQTheme.adaptive(light: FQTheme.hex(0x584400), dark: FQTheme.hex(0xFDCF4F))
        case .green: return FQTheme.adaptive(light: FQTheme.hex(0x0C5700), dark: FQTheme.hex(0x9FE59B))
        case .teal: return FQTheme.adaptive(light: FQTheme.hex(0x005348), dark: FQTheme.hex(0x99E2D3))
        case .blue: return FQTheme.adaptive(light: FQTheme.hex(0x00458C), dark: FQTheme.hex(0xC7D3FF))
        case .purple: return FQTheme.adaptive(light: FQTheme.hex(0x700084), dark: FQTheme.hex(0xFAC1FF))
        case .gray: return FQTheme.adaptive(light: FQTheme.hex(0x262626), dark: FQTheme.hex(0xE5E5E5))
        }
    }
}
