import SwiftUI
import AppKit

/// Draggable divider between a fixed-width pane and a flexible one.
///
/// `width` is the pane's current width; the handle clamps every update to
/// `range` and flips the drag direction for panes anchored to the trailing edge.
struct ResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    /// `true` when the resized pane sits to the RIGHT of this handle (an
    /// inspector), so dragging left grows it.
    var isTrailingPane = false
    var accessibilityName: String

    @State private var isHovering = false
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(FQTheme.border)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(
                // Thin line, fat hit area — the visible divider stays 1pt.
                Rectangle()
                    .fill(isHovering ? FQTheme.focusRing.opacity(0.5) : Color.clear)
                    .frame(width: 3)
            )
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else if dragStart == nil {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? width
                        if dragStart == nil { dragStart = start }
                        let delta = isTrailingPane ? -value.translation.width : value.translation.width
                        width = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        if !isHovering { NSCursor.pop() }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize \(accessibilityName)")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                let step: Double = 20
                switch direction {
                case .increment: width = min(width + step, range.upperBound)
                case .decrement: width = max(width - step, range.lowerBound)
                @unknown default: break
                }
            }
    }
}
