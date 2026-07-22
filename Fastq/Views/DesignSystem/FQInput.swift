import SwiftUI

/// Single-line text input matching the design system (rounded, bordered).
struct FQTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(FQTheme.fontBody)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(FQTheme.surface, in: RoundedRectangle(cornerRadius: FQTheme.radiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FQTheme.radiusMedium, style: .continuous)
                    .strokeBorder(focused ? FQTheme.focusRing : FQTheme.border, lineWidth: focused ? 2 : 1)
            )
            .focused($focused)
            .onSubmit { onSubmit?() }
    }
}

/// Multi-line growing input used for chat follow-ups inside cards.
struct FQTextArea: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 110

    var body: some View {
        TextEditor(text: $text)
            .font(FQTheme.fontBody)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(FQTheme.fontBody)
                        .foregroundStyle(FQTheme.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}
