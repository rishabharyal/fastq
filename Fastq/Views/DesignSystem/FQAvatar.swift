import SwiftUI

/// Circular avatar for chat participants: agent brand icon or initials.
struct FQAvatar: View {
    enum Kind {
        case agent(AgentToolKind)
        case initials(String)
    }

    let kind: Kind
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(FQTheme.surfaceSecondary)
            switch kind {
            case .agent(let tool):
                AgentBrandIcon(kind: tool, size: size * 0.55)
            case .initials(let text):
                Text(String(text.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(FQTheme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(FQTheme.border, lineWidth: 1))
    }
}
