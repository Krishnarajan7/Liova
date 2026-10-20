import AppKit

/// Liova's menu bar mark: the hand-lettered "Li" from the app icon, with the island dot.
///
/// The same letterforms as `scripts/icon/make-icon.swift`, scaled down and drawn slightly
/// bolder so hairlines survive at menu bar size. A template image, so macOS tints it for light
/// and dark menu bars and for the highlighted state, like the system's own icons.
enum MenuBarIcon {
    /// One cubic Bézier segment.
    private struct Segment {
        let start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint

        init(_ start: CGPoint, _ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint) {
            self.start = start
            self.control1 = control1
            self.control2 = control2
            self.end = end
        }
    }

    /// The "Li" path in the app icon's 1024-point design space.
    private static let letters: [Segment] = [
        Segment(CGPoint(x: 498, y: 640), CGPoint(x: 560, y: 700), CGPoint(x: 640, y: 790), CGPoint(x: 578, y: 818)),
        Segment(CGPoint(x: 578, y: 818), CGPoint(x: 530, y: 840), CGPoint(x: 470, y: 790), CGPoint(x: 470, y: 720)),
        Segment(CGPoint(x: 470, y: 720), CGPoint(x: 470, y: 600), CGPoint(x: 430, y: 450), CGPoint(x: 400, y: 350)),
        Segment(CGPoint(x: 400, y: 350), CGPoint(x: 385, y: 300), CGPoint(x: 320, y: 285), CGPoint(x: 318, y: 318)),
        Segment(CGPoint(x: 318, y: 318), CGPoint(x: 316, y: 350), CGPoint(x: 390, y: 340), CGPoint(x: 440, y: 316)),
        Segment(CGPoint(x: 440, y: 316), CGPoint(x: 500, y: 290), CGPoint(x: 560, y: 330), CGPoint(x: 600, y: 460)),
        Segment(CGPoint(x: 600, y: 460), CGPoint(x: 610, y: 400), CGPoint(x: 600, y: 330), CGPoint(x: 640, y: 318)),
        Segment(CGPoint(x: 640, y: 318), CGPoint(x: 680, y: 306), CGPoint(x: 712, y: 330), CGPoint(x: 736, y: 370)),
    ]

    static let image: NSImage = {
        let size = NSSize(width: 15, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Fit the letters' bounds (about x 314…740, y 282…842) into the image.
            let scale: CGFloat = 15 / 560
            ctx.translateBy(x: 0.6 - 314 * scale, y: 0.4 - 282 * scale)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor.black.cgColor)
            // In design-space points: heavier than the app icon so the mark reads at 16 pt.
            let thick: CGFloat = 86, thin: CGFloat = 30
            let points = samples()
            for (index, sample) in points.enumerated() {
                let progress = CGFloat(index) / CGFloat(max(points.count - 1, 1))
                let down = max(0, -sample.tangent.dy)
                var width = thin + (thick - thin) * pow(down, 1.4)
                width *= 0.5 + 0.5 * smoothstep(progress / 0.04) * smoothstep((1 - progress) / 0.06)
                ctx.saveGState()
                ctx.translateBy(x: sample.point.x, y: sample.point.y)
                ctx.rotate(by: -0.45)
                ctx.fillEllipse(in: CGRect(x: -width / 2, y: -width * 0.4, width: width, height: width * 0.8))
                ctx.restoreGState()
            }
            // The island dot, a little larger so it's visible.
            ctx.addPath(CGPath(
                roundedRect: CGRect(x: 548, y: 536, width: 130, height: 50),
                cornerWidth: 25, cornerHeight: 25, transform: nil
            ))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Liova"
        return image
    }()

    private static func samples(spacing: CGFloat = 6) -> [(point: CGPoint, tangent: CGVector)] {
        var dense: [CGPoint] = []
        for (index, segment) in letters.enumerated() {
            for step in 0 ... 200 where !(step == 0 && index > 0) {
                dense.append(cubic(segment, CGFloat(step) / 200))
            }
        }
        var result: [(CGPoint, CGVector)] = []
        var carry: CGFloat = 0
        for index in 1 ..< dense.count {
            let previous = dense[index - 1], current = dense[index]
            let deltaX = current.x - previous.x, deltaY = current.y - previous.y
            let length = (deltaX * deltaX + deltaY * deltaY).squareRoot()
            guard length > 0 else { continue }
            var distance = carry
            while distance < length {
                let fraction = distance / length
                result.append((
                    CGPoint(x: previous.x + deltaX * fraction, y: previous.y + deltaY * fraction),
                    CGVector(dx: deltaX / length, dy: deltaY / length)
                ))
                distance += spacing
            }
            carry = distance - length
        }
        return result
    }

    /// A point on a cubic Bézier segment, in Bernstein form.
    private static func cubic(_ segment: Segment, _ progress: CGFloat) -> CGPoint {
        let rest: CGFloat = 1 - progress
        let weightStart: CGFloat = rest * rest * rest
        let weightControl1: CGFloat = 3 * rest * rest * progress
        let weightControl2: CGFloat = 3 * rest * progress * progress
        let weightEnd: CGFloat = progress * progress * progress
        let x: CGFloat = weightStart * segment.start.x + weightControl1 * segment.control1.x
            + weightControl2 * segment.control2.x + weightEnd * segment.end.x
        let y: CGFloat = weightStart * segment.start.y + weightControl1 * segment.control1.y
            + weightControl2 * segment.control2.y + weightEnd * segment.end.y
        return CGPoint(x: x, y: y)
    }

    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
