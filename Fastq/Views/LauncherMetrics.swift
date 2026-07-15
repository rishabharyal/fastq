import CoreGraphics

/// Industry-standard launcher panel metrics (Raycast-class + macOS HIG hit targets).
enum LauncherMetrics {
    static let panelWidth: CGFloat = 750
    static let panelExpandedHeight: CGFloat = 480
    static let cornerRadius: CGFloat = 12

    static let headerPaddingH: CGFloat = 16
    static let headerPaddingTop: CGFloat = 14
    static let headerPaddingBottom: CGFloat = 10

    static let promptMinHeight: CGFloat = 24
    static let promptMaxHeight: CGFloat = 72
    static let iconButtonSize: CGFloat = 28

    static let chipFontSize: CGFloat = 12
    static let chipIconSize: CGFloat = 10
    static let chipPaddingH: CGFloat = 8
    static let chipPaddingV: CGFloat = 5
    static let chipSpacing: CGFloat = 6

    static let rowMinHeight: CGFloat = 44
    static let rowIconSize: CGFloat = 32
    static let rowIconCornerRadius: CGFloat = 8
    static let rowCornerRadius: CGFloat = 8
    static let rowPaddingH: CGFloat = 12
    static let rowPaddingV: CGFloat = 8
    static let rowSpacing: CGFloat = 4
    static let listHorizontalInset: CGFloat = 10
    static let listSectionTitleSize: CGFloat = 11

    static let footerPaddingH: CGFloat = 16
    static let footerPaddingV: CGFloat = 8
    static let footerFontSize: CGFloat = 12
    static let keyCapFontSize: CGFloat = 11
    static let keyCapPaddingH: CGFloat = 5
    static let keyCapPaddingV: CGFloat = 2
    static let keyCapCornerRadius: CGFloat = 4
}
