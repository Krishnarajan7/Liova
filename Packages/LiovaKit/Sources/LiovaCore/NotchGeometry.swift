import CoreGraphics

/// Raw measurements of one screen, in AppKit screen coordinates (origin bottom-left, points).
///
/// A plain value so geometry can be computed and unit-tested without `NSScreen`.
public struct ScreenMetrics: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`; non-zero only on screens with a camera housing.
    public var safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea`: the menu bar area left of the notch.
    public var auxiliaryTopLeft: CGRect?
    /// `NSScreen.auxiliaryTopRightArea`: the menu bar area right of the notch.
    public var auxiliaryTopRight: CGRect?
    public var backingScale: CGFloat

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat = 0,
        auxiliaryTopLeft: CGRect? = nil,
        auxiliaryTopRight: CGRect? = nil,
        backingScale: CGFloat = 2
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.backingScale = backingScale
    }

    /// Height of the menu bar, or 0 when it is hidden.
    public var menuBarHeight: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }
}

/// Where the notch is on a screen and how big it is when closed.
///
/// On a screen with a camera housing the notch matches the hardware exactly.
/// Everywhere else Liova draws a virtual notch, centered at the top edge.
public struct NotchGeometry: Equatable, Sendable {
    /// Default size of the virtual notch on screens without a camera housing.
    public static let virtualNotchWidth: CGFloat = 190
    public static let minimumNotchHeight: CGFloat = 24

    public let screenFrame: CGRect
    public let hasHardwareNotch: Bool
    /// The closed notch, in screen coordinates.
    public let notchFrame: CGRect
    public let backingScale: CGFloat

    public init(metrics: ScreenMetrics, virtualNotchWidth: CGFloat = Self.virtualNotchWidth) {
        screenFrame = metrics.frame
        backingScale = max(metrics.backingScale, 1)

        if let hardware = Self.hardwareNotch(in: metrics) {
            hasHardwareNotch = true
            notchFrame = hardware
        } else {
            hasHardwareNotch = false
            let height = max(metrics.menuBarHeight, Self.minimumNotchHeight)
            let width = min(virtualNotchWidth, metrics.frame.width)
            notchFrame = CGRect(
                x: metrics.frame.midX - width / 2,
                y: metrics.frame.maxY - height,
                width: width,
                height: height
            )
        }
    }

    public var notchSize: CGSize {
        notchFrame.size
    }

    /// The fixed frame of the notch panel for a given content size: top-aligned to the
    /// screen, centered on the notch, kept inside the screen, and pixel-aligned.
    public func panelFrame(contentSize: CGSize) -> CGRect {
        let width = min(contentSize.width, screenFrame.width)
        let height = min(contentSize.height, screenFrame.height)
        var originX = notchFrame.midX - width / 2
        originX = min(max(originX, screenFrame.minX), screenFrame.maxX - width)
        let rect = CGRect(x: originX, y: screenFrame.maxY - height, width: width, height: height)
        return pixelAligned(rect)
    }

    /// Rounds a rect outward to whole device pixels so edges never blur.
    public func pixelAligned(_ rect: CGRect) -> CGRect {
        let scale = backingScale
        let minX = (rect.minX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale
        let maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func hardwareNotch(in metrics: ScreenMetrics) -> CGRect? {
        guard metrics.safeAreaTop > 0,
              let left = metrics.auxiliaryTopLeft,
              let right = metrics.auxiliaryTopRight
        else { return nil }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        let height = metrics.safeAreaTop
        return CGRect(x: left.maxX, y: metrics.frame.maxY - height, width: width, height: height)
    }
}
