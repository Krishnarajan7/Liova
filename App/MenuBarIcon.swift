import AppKit

/// Liova's menu bar mark: the "L" from the app icon, whose foot is the island, with the
/// waveform cut out of it.
///
/// Drawn in code as a template image, so macOS tints it for light and dark menu bars and for
/// the highlighted state, like the system's own icons.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            // Stem: rounded at the top, flowing straight into the foot's rounded left end.
            let stem = NSBezierPath()
            let stemLeft: CGFloat = 2, stemRight: CGFloat = 6.4, stemTop: CGFloat = 15
            stem.move(to: NSPoint(x: stemLeft, y: 4))
            stem.line(to: NSPoint(x: stemLeft, y: stemTop - 2.2))
            stem.appendArc(
                withCenter: NSPoint(x: stemLeft + 2.2, y: stemTop - 2.2),
                radius: 2.2,
                startAngle: 180,
                endAngle: 0,
                clockwise: true
            )
            stem.line(to: NSPoint(x: stemRight, y: 4))
            stem.close()
            // Foot: the island.
            let foot = NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 15, height: 6.6), xRadius: 3.3, yRadius: 3.3)
            NSColor.black.setFill()
            stem.fill()
            foot.fill()
            // Cut the waveform out of the island.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for (x, height) in [(6.2, 2.4), (8.3, 4.0), (10.4, 3.0), (12.5, 4.0), (14.6, 2.2)] where x + 1.2 < 16.5 {
                NSBezierPath(
                    roundedRect: NSRect(x: x - 0.6, y: 4.3 - height / 2, width: 1.2, height: height),
                    xRadius: 0.6,
                    yRadius: 0.6
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Liova"
        return image
    }()
}
