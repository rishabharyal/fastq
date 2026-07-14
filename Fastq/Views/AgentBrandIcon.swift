import SwiftUI
import AppKit

/// Compact brand mark for an agent tool.
/// Uses SF Symbol fallbacks with brand tints — asset PNGs are optional and
/// only used when they load as a real template (avoids the huge gray qlmanage blobs).
struct AgentBrandIcon: View {
    let kind: AgentToolKind
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.85, weight: .semibold))
            .foregroundStyle(kind.brandTint)
            .frame(width: size, height: size, alignment: .center)
            .accessibilityLabel(kind.shortName)
    }
}

extension AgentToolKind {
    var brandAssetName: String? {
        switch self {
        case .cursorCLI: return "AgentCursor"
        case .claudeCode: return "AgentClaude"
        case .codexCLI: return "AgentCodex"
        case .grokAgent: return "AgentGrok"
        case .openCode: return "AgentOpenCode"
        }
    }

    var brandTint: Color {
        switch self {
        case .cursorCLI: return Color(red: 0.85, green: 0.85, blue: 0.90)
        case .claudeCode: return Color(red: 0.85, green: 0.55, blue: 0.35)
        case .codexCLI: return Color(red: 0.45, green: 0.78, blue: 0.55)
        case .grokAgent: return Color(red: 0.95, green: 0.95, blue: 0.95)
        case .openCode: return Color(red: 0.45, green: 0.65, blue: 0.95)
        }
    }
}
