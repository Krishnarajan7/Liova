// Draws Liova's app icon and writes every size macOS needs into an .appiconset.
//
//   swift scripts/icon/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Design: a hand-lettered "Li" in brush script on warm paper. The pen is heavy on downstrokes
// and hairline on upstrokes, like real penmanship, and the dot of the "i" is a tiny Dynamic
// Island. Drawn from code by stamping an angled brush tip along the letter's path, so it's
// sharp at every size and fully our own (no font). Follows Apple's macOS icon grid:
// 1024 canvas, 824 squircle, continuous corners.
import AppKit
import CoreGraphics

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset"
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

let ink = color(0.05, 0.05, 0.06)
let paper = color(0.985, 0.98, 0.97)

typealias Segment = (CGPoint, CGPoint, CGPoint, CGPoint)

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

func cubic(_ s: Segment, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return point(a * s.0.x + b * s.1.x + c * s.2.x + d * s.3.x, a * s.0.y + b * s.1.y + c * s.2.y + d * s.3.y)
}

func smoothstep(_ x: CGFloat) -> CGFloat {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
}

/// The "Li": a looped capital L flowing straight into the i, as one stroke.
let letters: [Segment] = [
    (point(498, 640), point(560, 700), point(640, 790), point(578, 818)), // entry hairline into the top loop
    (point(578, 818), point(530, 840), point(470, 790), point(470, 720)),
    (point(470, 720), point(470, 600), point(430, 450), point(400, 350)), // the long stem
    (point(400, 350), point(385, 300), point(320, 285), point(318, 318)), // bottom loop
    (point(318, 318), point(316, 350), point(390, 340), point(440, 316)),
    (point(440, 316), point(500, 290), point(560, 330), point(600, 460)), // rising into the i
    (point(600, 460), point(610, 400), point(600, 330), point(640, 318)), // the i
    (point(640, 318), point(680, 306), point(712, 330), point(736, 370)), // exit flick
]

/// Points every `spacing` along the path, with the direction of travel.
func samples(_ segments: [Segment], spacing: CGFloat = 1.2) -> [(point: CGPoint, tangent: CGVector)] {
    var dense: [CGPoint] = []
    for (index, segment) in segments.enumerated() {
        for step in 0 ... 400 where !(step == 0 && index > 0) {
            dense.append(cubic(segment, CGFloat(step) / 400))
        }
    }
    var result: [(CGPoint, CGVector)] = []
    var carry: CGFloat = 0
    for index in 1 ..< dense.count {
        let a = dense[index - 1], b = dense[index]
        let dx = b.x - a.x, dy = b.y - a.y, length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { continue }
        var distance = carry
        while distance < length {
            let t = distance / length
            result.append((point(a.x + dx * t, a.y + dy * t), CGVector(dx: dx / length, dy: dy / length)))
            distance += spacing
        }
        carry = distance - length
    }
    return result
}

func render(size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.interpolationQuality = .high

    // Paper tile with a soft shadow.
    let tile = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0, 0, 0, 0.3))
    ctx.addPath(tile)
    ctx.setFillColor(paper)
    ctx.fillPath()
    ctx.restoreGState()

    // The letters: an angled, slightly flat brush tip stamped along the path. Heavy when the
    // pen moves down, hairline when it moves up, tapered at both ends.
    let thick: CGFloat = 62, thin: CGFloat = 14
    let points = samples(letters)
    ctx.setFillColor(ink)
    for (index, sample) in points.enumerated() {
        let t = CGFloat(index) / CGFloat(max(points.count - 1, 1))
        let down = max(0, -sample.tangent.dy)
        var width = thin + (thick - thin) * pow(down, 1.4)
        width *= 0.35 + 0.65 * smoothstep(t / 0.04) * smoothstep((1 - t) / 0.06)
        ctx.saveGState()
        ctx.translateBy(x: sample.point.x, y: sample.point.y)
        ctx.rotate(by: -0.45)
        ctx.fillEllipse(in: CGRect(x: -width / 2, y: -width * 0.4, width: width, height: width * 0.8))
        ctx.restoreGState()
    }

    // The dot of the i is a tiny Dynamic Island.
    ctx.addPath(roundedRect(CGRect(x: 560, y: 542, width: 106, height: 36), 18))
    ctx.fillPath()
    return ctx.makeImage()!
}

let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: render(size: points * scale))
    try rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: output).appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icon sizes to \(output)")
