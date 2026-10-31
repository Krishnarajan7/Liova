import CoreGraphics
@testable import LiovaFeatures
import Testing

@MainActor
struct SystemPageTests {
    @Test func processorsGetBusyBeforeMemoryDoes() {
        #expect(LoadLevel(0.65, on: .load) == .busy)
        #expect(LoadLevel(0.65, on: .memory) == .calm)
        #expect(LoadLevel(0.9, on: .load) == .maxed)
        #expect(LoadLevel(0.9, on: .memory) == .busy)
        #expect(LoadLevel(0.95, on: .memory) == .maxed)
    }

    @Test func barsFillFromTheRightAndOlderOnesFade() {
        let size = CGSize(width: 179, height: 24)
        let bars = LoadHistory.bars([0.1, 0.5, 1], in: size)
        #expect(bars.count == 3)
        // The newest bar ends at the right edge, full height.
        let newest = bars[2].rect
        #expect(abs(newest.maxX - size.width) < 0.01)
        #expect(newest.height == size.height)
        #expect(bars[0].opacity < bars[1].opacity)
        #expect(bars[2].opacity == 1)
    }

    @Test func aQuietReadingIsStillVisible() {
        let bars = LoadHistory.bars([0], in: CGSize(width: 179, height: 24))
        #expect(bars[0].rect.height > 0)
    }

    @Test func aFullMinuteFitsExactly() {
        let size = CGSize(width: 179, height: 24)
        let bars = LoadHistory.bars(Array(repeating: 0.5, count: SystemMonitorFeature.historyLength), in: size)
        #expect(abs(bars[0].rect.minX) < 0.01)
        #expect(abs(bars[bars.count - 1].rect.maxX - size.width) < 0.01)
    }
}
