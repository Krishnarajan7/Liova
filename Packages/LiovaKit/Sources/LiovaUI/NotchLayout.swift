import CoreGraphics
import LiovaCore

/// What the notch is doing on one display.
public enum NotchPresentation: Equatable, Sendable {
    /// At rest: matches the hardware notch, or shows compact "ears" when an activity is live.
    case closed
    /// The pointer is on the notch; a small grow invites a click or a longer hover.
    case peek
    /// Fully open with rich content.
    case expanded
}

/// The size and corner radii the notch should have. Pure, so it is unit-tested.
public struct NotchSpec: Equatable, Sendable {
    /// Width of the black body, excluding the top flares.
    public var bodyWidth: CGFloat
    public var height: CGFloat
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    /// Full width of the shape including both top flares.
    public var shapeWidth: CGFloat {
        bodyWidth + 2 * topRadius
    }

    public var shapeSize: CGSize {
        CGSize(width: shapeWidth, height: height)
    }
}

public enum NotchLayout {
    /// Size of the expanded notch body at its tallest. It fits its content, so a one-line
    /// card gets a short notch instead of a slab of empty black.
    public static let expandedBodySize = CGSize(width: 480, height: 124)
    /// The shortest the open notch gets below the camera row.
    public static let minExpandedBodyHeight: CGFloat = 64
    /// Room around the expanded notch for its shadow. Part of the fixed panel.
    public static let shadowMargin: CGFloat = 24
    /// How much the notch grows on hover.
    public static let peekGrowth = CGSize(width: 16, height: 4)

    /// The fixed panel size for a display: big enough for the largest state, never resized.
    public static func panelSize(for geometry: NotchGeometry) -> CGSize {
        let expanded = spec(for: .expanded, geometry: geometry, hasActivity: false)
        return CGSize(
            width: expanded.shapeWidth + 2 * shadowMargin,
            height: expanded.height + shadowMargin
        )
    }

    /// Width of each compact "ear" beside the hardware notch.
    public static func earWidth(for geometry: NotchGeometry) -> CGFloat {
        (geometry.notchSize.height * 1.15).rounded()
    }

    /// The open notch's height below the camera row for content needing `contentHeight`:
    /// that, within the minimum and maximum. Unmeasured content gets the maximum.
    public static func expandedBodyHeight(for contentHeight: CGFloat?) -> CGFloat {
        guard let contentHeight else { return expandedBodySize.height }
        return min(max(contentHeight.rounded(.up), minExpandedBodyHeight), expandedBodySize.height)
    }

    /// `contentHeight` sizes the open notch to fit (see `expandedBodyHeight(for:)`); other
    /// presentations ignore it.
    public static func spec(
        for presentation: NotchPresentation,
        geometry: NotchGeometry,
        hasActivity: Bool,
        contentHeight: CGFloat? = nil
    ) -> NotchSpec {
        let notch = geometry.notchSize
        let closedRadius = min(notch.height * 0.3, 12)
        let closedWidth = hasActivity ? notch.width + 2 * earWidth(for: geometry) : notch.width
        let closed = NotchSpec(bodyWidth: closedWidth, height: notch.height, topRadius: 6, bottomRadius: closedRadius)

        switch presentation {
        case .closed:
            return closed
        case .peek:
            return NotchSpec(
                bodyWidth: closed.bodyWidth + peekGrowth.width,
                height: closed.height + peekGrowth.height,
                topRadius: closed.topRadius,
                bottomRadius: closed.bottomRadius + 2
            )
        case .expanded:
            return NotchSpec(
                bodyWidth: max(expandedBodySize.width, closedWidth + 40),
                height: notch.height + expandedBodyHeight(for: contentHeight),
                topRadius: 14,
                bottomRadius: 28
            )
        }
    }

    /// The shape's rect in screen coordinates, given the panel's screen frame.
    /// The shape is centered horizontally at the top of the panel.
    public static func shapeFrame(_ spec: NotchSpec, inPanel panel: CGRect) -> CGRect {
        CGRect(
            x: panel.midX - spec.shapeWidth / 2,
            y: panel.maxY - spec.height,
            width: spec.shapeWidth,
            height: spec.height
        )
    }

    /// The area that counts as "on the notch" for the pointer. Extends a little below
    /// and to the sides, and includes the very top edge of the screen, so slamming the
    /// pointer into the top of the display still hits it.
    public static func hotZone(_ spec: NotchSpec, inPanel panel: CGRect, slop: CGFloat) -> CGRect {
        let shape = shapeFrame(spec, inPanel: panel)
        return CGRect(
            x: shape.minX - slop,
            y: shape.minY - slop,
            width: shape.width + 2 * slop,
            height: shape.height + slop + 1
        )
    }
}
