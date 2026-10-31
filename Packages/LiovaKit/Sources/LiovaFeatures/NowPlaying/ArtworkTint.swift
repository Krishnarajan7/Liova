import AppKit

/// The colour the closed notch's music wave takes from the album art. Pure, so it's tested.
enum ArtworkTint {
    /// Side of the grid the artwork is sampled at: enough to find its colours, and cheap.
    static let sampleSide = 12
    /// How many of the most vivid samples are averaged, so one stray pixel can't decide.
    static let vividSamples = 10

    /// The artwork's most vivid colour, lifted so it reads on the black notch; `nil` when the
    /// art has no real colour (black and white, or nearly), and the caller's default is used.
    static func color(of image: CGImage) -> NSColor? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        let samples = stride(from: 0, to: pixels.count, by: 4).map { offset -> NSColor in
            let red = CGFloat(pixels[offset]) / 255
            let green = CGFloat(pixels[offset + 1]) / 255
            let blue = CGFloat(pixels[offset + 2]) / 255
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        return color(ofSamples: samples)
    }

    static func color(ofSamples samples: [NSColor]) -> NSColor? {
        // Vivid means saturated and not too dark: a dark red counts less than a bright one.
        let scored = samples.map { sample -> (color: NSColor, score: CGFloat) in
            (sample, sample.saturationComponent * (0.3 + 0.7 * sample.brightnessComponent))
        }
        let vivid = scored.sorted { $0.score > $1.score }.prefix(vividSamples)
        guard let best = vivid.first, best.score > 0.12 else { return nil }

        let count = CGFloat(vivid.count)
        let average = NSColor(
            srgbRed: vivid.map(\.color.redComponent).reduce(0, +) / count,
            green: vivid.map(\.color.greenComponent).reduce(0, +) / count,
            blue: vivid.map(\.color.blueComponent).reduce(0, +) / count,
            alpha: 1
        )
        // Bright enough to read as a thin line on black, never neon.
        return NSColor(
            hue: average.hueComponent,
            saturation: min(max(average.saturationComponent, 0.35), 0.8),
            brightness: max(average.brightnessComponent, 0.88),
            alpha: 1
        )
    }
}
