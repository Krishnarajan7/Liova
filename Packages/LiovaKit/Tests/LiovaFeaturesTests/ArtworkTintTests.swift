import AppKit
@testable import LiovaFeatures
import Testing

struct ArtworkTintTests {
    private func image(_ fill: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        fill(context)
        return try #require(context.makeImage())
    }

    @Test func picksTheVividColourOverAGreyBackground() throws {
        let art = try image { context in
            context.setFillColor(gray: 0.3, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.setFillColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let tint = try #require(ArtworkTint.color(of: art))
        // Blue, lifted to read on black.
        #expect((0.55 ... 0.7).contains(tint.hueComponent))
        #expect(tint.brightnessComponent >= 0.88)
    }

    @Test func blackAndWhiteArtHasNoTint() throws {
        let art = try image { context in
            context.setFillColor(gray: 0.05, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.setFillColor(gray: 0.95, alpha: 1)
            context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        }
        #expect(ArtworkTint.color(of: art) == nil)
    }

    @Test func aDarkColourIsLiftedButNeverNeon() throws {
        let tint = try #require(ArtworkTint.color(ofSamples: Array(
            repeating: NSColor(srgbRed: 0.35, green: 0.02, blue: 0.05, alpha: 1), count: 20
        )))
        #expect(tint.brightnessComponent >= 0.88)
        #expect(tint.saturationComponent <= 0.8)
    }
}
