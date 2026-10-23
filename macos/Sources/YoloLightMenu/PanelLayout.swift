import Foundation

/// A viewport is chosen once per presentation, never from changing control values.
/// Reserve one row even before discovery completes; additional arrivals can scroll.
struct PanelLayout: Equatable {
    static let width: CGFloat = 300
    static let padding: CGFloat = 12
    static let footerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 123
    static let rowSpacing: CGFloat = 12
    static let separatorHeight: CGFloat = 1
    static let maximumViewportHeight: CGFloat = 420

    let viewportHeight: CGFloat

    init(lightCount: Int) {
        let rows = CGFloat(max(1, lightCount))
        viewportHeight = min(Self.maximumViewportHeight,
            rows * Self.rowHeight + (rows - 1) * (2 * Self.rowSpacing + Self.separatorHeight))
    }

    var size: CGSize {
        CGSize(width: Self.width, height: viewportHeight + 2 * Self.padding)
    }
}
