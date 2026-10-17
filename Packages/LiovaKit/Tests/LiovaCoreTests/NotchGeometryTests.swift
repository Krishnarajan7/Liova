import CoreGraphics
import LiovaCore
import Testing

/// Values recorded from real hardware with `NSScreen`.
enum Fixtures {
    /// MacBook Air M4 13", "More Space" scaling (1710×1112 pt).
    static let macBookAirM4 = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        safeAreaTop: 38,
        auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 751, height: 38),
        auxiliaryTopRight: CGRect(x: 960, y: 1074, width: 750, height: 38),
        backingScale: 2
    )

    /// 27" external display at 2560×1440, placed to the right of the laptop.
    static let externalRight = ScreenMetrics(
        frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1710, y: 0, width: 2560, height: 1415),
        backingScale: 1
    )

    /// Display with the menu bar set to auto-hide.
    static let hiddenMenuBar = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScale: 2
    )
}

struct NotchGeometryTests {
    @Test func hardwareNotchMatchesCameraHousing() {
        let geometry = NotchGeometry(metrics: Fixtures.macBookAirM4)
        #expect(geometry.hasHardwareNotch)
        #expect(geometry.notchFrame == CGRect(x: 751, y: 1074, width: 209, height: 38))
    }

    @Test func virtualNotchIsCenteredAndMenuBarTall() {
        let geometry = NotchGeometry(metrics: Fixtures.externalRight)
        #expect(!geometry.hasHardwareNotch)
        #expect(geometry.notchSize == CGSize(width: NotchGeometry.virtualNotchWidth, height: 25))
        #expect(geometry.notchFrame.midX == Fixtures.externalRight.frame.midX)
        #expect(geometry.notchFrame.maxY == 1440)
    }

    @Test func virtualNotchHasMinimumHeightWhenMenuBarHidden() {
        let geometry = NotchGeometry(metrics: Fixtures.hiddenMenuBar)
        #expect(geometry.notchSize.height == NotchGeometry.minimumNotchHeight)
    }

    @Test func safeAreaWithoutAuxiliaryAreasIsNotANotch() {
        var metrics = Fixtures.macBookAirM4
        metrics.auxiliaryTopRight = nil
        #expect(!NotchGeometry(metrics: metrics).hasHardwareNotch)
    }

    @Test func panelIsTopAlignedAndCenteredOnNotch() {
        let geometry = NotchGeometry(metrics: Fixtures.macBookAirM4)
        let panel = geometry.panelFrame(contentSize: CGSize(width: 640, height: 260))
        #expect(panel.maxY == 1112)
        #expect(abs(panel.midX - geometry.notchFrame.midX) <= 0.5)
        #expect(panel.size == CGSize(width: 640, height: 260))
    }

    @Test func panelStaysInsideScreenOnSecondaryDisplay() {
        let geometry = NotchGeometry(metrics: Fixtures.externalRight)
        let panel = geometry.panelFrame(contentSize: CGSize(width: 640, height: 260))
        #expect(panel.minX >= 1710)
        #expect(panel.maxX <= 1710 + 2560)
        #expect(panel.maxY == 1440)
    }

    @Test func panelNeverExceedsScreen() {
        let geometry = NotchGeometry(metrics: Fixtures.hiddenMenuBar)
        let panel = geometry.panelFrame(contentSize: CGSize(width: 5000, height: 5000))
        #expect(panel == Fixtures.hiddenMenuBar.frame)
    }

    @Test func pixelAlignmentRoundsOutward() {
        let geometry = NotchGeometry(metrics: Fixtures.macBookAirM4)
        let rect = geometry.pixelAligned(CGRect(x: 10.3, y: 20.6, width: 100.1, height: 10))
        #expect(rect.minX == 10)
        #expect(rect.minY == 20.5)
        #expect(rect.maxX == 110.5)
        #expect(rect.maxY == 31)
    }
}
