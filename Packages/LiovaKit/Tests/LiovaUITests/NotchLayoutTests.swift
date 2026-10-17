import CoreGraphics
import LiovaCore
@testable import LiovaUI
import Testing

private let airM4 = NotchGeometry(metrics: ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
    visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
    safeAreaTop: 38,
    auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 751, height: 38),
    auxiliaryTopRight: CGRect(x: 960, y: 1074, width: 750, height: 38)
))

struct NotchLayoutTests {
    @Test func closedBodyCoversHardwareNotchExactly() {
        let spec = NotchLayout.spec(for: .closed, geometry: airM4, hasActivity: false)
        #expect(spec.bodyWidth == 209)
        #expect(spec.height == 38)
    }

    @Test func closedShapeAlignsWithCameraHousingOnScreen() {
        let panel = airM4.panelFrame(contentSize: NotchLayout.panelSize(for: airM4))
        let spec = NotchLayout.spec(for: .closed, geometry: airM4, hasActivity: false)
        let shape = NotchLayout.shapeFrame(spec, inPanel: panel)
        let body = shape.insetBy(dx: spec.topRadius, dy: 0)
        #expect(abs(body.minX - airM4.notchFrame.minX) <= 0.5)
        #expect(abs(body.maxX - airM4.notchFrame.maxX) <= 0.5)
        #expect(shape.maxY == airM4.notchFrame.maxY)
    }

    @Test func activityAddsEarsWithoutChangingHeight() {
        let idle = NotchLayout.spec(for: .closed, geometry: airM4, hasActivity: false)
        let live = NotchLayout.spec(for: .closed, geometry: airM4, hasActivity: true)
        #expect(live.bodyWidth == idle.bodyWidth + 2 * NotchLayout.earWidth(for: airM4))
        #expect(live.height == idle.height)
    }

    @Test func statesGrowMonotonically() {
        let closed = NotchLayout.spec(for: .closed, geometry: airM4, hasActivity: true)
        let peek = NotchLayout.spec(for: .peek, geometry: airM4, hasActivity: true)
        let expanded = NotchLayout.spec(for: .expanded, geometry: airM4, hasActivity: true)
        #expect(closed.shapeWidth < peek.shapeWidth)
        #expect(peek.shapeWidth < expanded.shapeWidth)
        #expect(closed.height < peek.height)
        #expect(peek.height < expanded.height)
    }

    @Test(arguments: [NotchPresentation.closed, .peek, .expanded], [false, true])
    func everyStateFitsInsideTheFixedPanel(presentation: NotchPresentation, hasActivity: Bool) {
        let panel = NotchLayout.panelSize(for: airM4)
        let spec = NotchLayout.spec(for: presentation, geometry: airM4, hasActivity: hasActivity)
        #expect(spec.shapeWidth <= panel.width)
        #expect(spec.height <= panel.height)
    }

    @Test func hotZoneIncludesTopEdgeOfScreen() {
        let panel = airM4.panelFrame(contentSize: NotchLayout.panelSize(for: airM4))
        let spec = NotchLayout.spec(for: .closed, geometry: airM4, hasActivity: false)
        let zone = NotchLayout.hotZone(spec, inPanel: panel, slop: 4)
        #expect(zone.contains(CGPoint(x: airM4.notchFrame.midX, y: 1112 - 0.01)))
        #expect(!zone.contains(CGPoint(x: airM4.notchFrame.midX, y: 1112 - 80)))
    }
}

struct NotchShapeTests {
    @Test func pathFitsInRect() {
        let rect = CGRect(x: 0, y: 0, width: 221, height: 38)
        let path = NotchShape(topRadius: 6, bottomRadius: 11).path(in: rect)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
        #expect(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
    }

    @Test func degenerateRadiiDoNotProduceInvalidPaths() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 10)
        let path = NotchShape(topRadius: 500, bottomRadius: 500).path(in: rect)
        #expect(!path.isEmpty)
        #expect(path.boundingRect.width <= 20.01)
    }

    @Test func radiiAreAnimatable() {
        var shape = NotchShape(topRadius: 6, bottomRadius: 10)
        shape.animatableData = .init(14, 28)
        #expect(shape.topRadius == 14)
        #expect(shape.bottomRadius == 28)
    }
}

struct EqualizerBarsTests {
    @Test func levelsStayInRangeAndMove() {
        var previous: [CGFloat] = []
        var changes = 0
        for step in 0 ..< 200 {
            let levels = EqualizerBarsView.levels(at: Double(step) / 10, count: 4)
            #expect(levels.count == 4)
            #expect(levels.allSatisfy { $0 >= 0.2 && $0 <= 1 })
            if !previous.isEmpty, levels != previous {
                changes += 1
            }
            previous = levels
        }
        #expect(changes > 190)
    }
}
