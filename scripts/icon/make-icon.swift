// Draws Liova's app icon and writes every size macOS needs into an .appiconset.
//
//   swift scripts/icon/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Design: a bold "L" for Liova whose foot is the island: a black Dynamic Island with a live,
// glowing waveform inside. One rim of light traces the whole letter, cyan to violet to pink,
// on a deep night-blue tile. Drawn from code so it stays sharp and editable. Follows Apple's
// macOS icon grid: 1024 canvas, 824 squircle, continuous corners.
import AppKit
import CoreGraphics

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset"
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func rr(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

func grad(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func draw(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = rr(tile, 185)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: c(0, 0, 0, 0.4))
    ctx.addPath(tilePath); ctx.setFillColor(c(0.05, 0.06, 0.14)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(
        grad([c(0.10, 0.11, 0.26), c(0.02, 0.02, 0.06)], [0, 1]),
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )
    // Soft glow behind the island.
    ctx.drawRadialGradient(
        grad([c(0.60, 0.40, 1.0, 0.45), c(0.60, 0.40, 1.0, 0)], [0, 1]),
        startCenter: CGPoint(x: 540, y: 390),
        startRadius: 0,
        endCenter: CGPoint(x: 540, y: 390),
        endRadius: 380,
        options: []
    )
    ctx.restoreGState()

    // The L is one continuous shape: a stem whose left edge flows tangentially into the
    // island's rounded left end, so there's no seam or bump where they meet.
    let foot = CGRect(x: 290, y: 290, width: 460, height: 180)
    let footPath = rr(foot, 90)
    let stem = CGMutablePath()
    let stemLeft: CGFloat = 290, stemRight: CGFloat = 418, stemTop: CGFloat = 780, stemBottom: CGFloat = foot.midY
    stem.move(to: CGPoint(x: stemLeft, y: stemBottom))
    stem.addLine(to: CGPoint(x: stemLeft, y: stemTop - 64))
    stem.addArc(
        center: CGPoint(x: stemLeft + 64, y: stemTop - 64),
        radius: 64,
        startAngle: .pi,
        endAngle: 0,
        clockwise: true
    )
    stem.addLine(to: CGPoint(x: stemRight, y: stemBottom))
    stem.closeSubpath()
    let letter = stem.union(footPath)

    // Glow and black body.
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 50, color: c(0.62, 0.42, 1.0, 0.7))
    ctx.addPath(letter); ctx.setFillColor(c(0.0, 0.0, 0.01)); ctx.fillPath(); ctx.restoreGState()
    // The stem above the island is lit with the gradient.
    ctx.saveGState(); ctx.addPath(letter); ctx.clip(); ctx.clip(to: CGRect(
        x: 0,
        y: foot.maxY,
        width: 1024,
        height: 600
    ))
    ctx.drawLinearGradient(
        grad([c(0.40, 0.85, 1.0), c(0.58, 0.50, 1.0)], [0, 1]),
        start: CGPoint(x: 0, y: stemTop),
        end: CGPoint(x: 0, y: foot.maxY),
        options: []
    )
    ctx.restoreGState()
    // One rim tracing the whole letter: cyan at the top, through violet, to pink at the end.
    ctx.saveGState(); ctx.addPath(letter); ctx.setLineWidth(8); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(
        grad([c(0.40, 0.85, 1.0), c(0.65, 0.48, 1.0), c(1.0, 0.42, 0.65)], [0, 0.5, 1]),
        start: CGPoint(x: 290, y: 780),
        end: CGPoint(x: 750, y: 290),
        options: []
    )
    ctx.restoreGState()

    // Waveform inside the island.
    let heights: [CGFloat] = [46, 84, 120, 72, 104, 58]
    let barWidth: CGFloat = 22, gap: CGFloat = 20
    let startX: CGFloat = 400
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: startX + CGFloat(i) * (barWidth + gap), y: 380 - h / 2, width: barWidth, height: h)
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 16, color: c(0.85, 0.45, 1.0, 0.8))
        ctx.addPath(rr(r, barWidth / 2)); ctx.clip()
        ctx.drawLinearGradient(
            grad([c(0.40, 0.85, 1.0), c(0.75, 0.45, 1.0), c(1.0, 0.45, 0.65)], [0, 0.5, 1]),
            start: CGPoint(x: startX, y: 0),
            end: CGPoint(x: startX + 6 * (barWidth + gap), y: 0),
            options: []
        )
        ctx.restoreGState()
    }
    // Hairline glass edge on the tile.
    ctx.addPath(tilePath); ctx.setStrokeColor(c(1, 1, 1, 0.08)); ctx.setLineWidth(3); ctx.strokePath()
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
    draw(ctx)
    return ctx.makeImage()!
}

let sizes: [(points: Int, scale: Int)] = [
    (16, 1),
    (16, 2),
    (32, 1),
    (32, 2),
    (128, 1),
    (128, 2),
    (256, 1),
    (256, 2),
    (512, 1),
    (512, 2),
]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scale) in sizes {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: render(size: pixels))
    try rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: URL(fileURLWithPath: output).appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icon sizes to \(output)")
