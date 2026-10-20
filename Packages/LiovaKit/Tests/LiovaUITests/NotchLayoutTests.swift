import AppKit
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

    @Test func openNotchFitsItsContent() {
        let full = NotchLayout.spec(for: .expanded, geometry: airM4, hasActivity: false)
        let oneLine = NotchLayout.spec(for: .expanded, geometry: airM4, hasActivity: false, contentHeight: 80)
        #expect(oneLine.height == airM4.notchSize.height + 80)
        #expect(oneLine.bodyWidth == full.bodyWidth)
        // Never shorter than the minimum, never taller than the panel allows.
        #expect(NotchLayout.expandedBodyHeight(for: 10) == NotchLayout.minExpandedBodyHeight)
        #expect(NotchLayout.expandedBodyHeight(for: 900) == NotchLayout.expandedBodySize.height)
        #expect(NotchLayout.expandedBodyHeight(for: nil) == NotchLayout.expandedBodySize.height)
        #expect(NotchLayout.expandedBodyHeight(for: 80.2) == 81)
        // Closed and peek ignore it.
        #expect(NotchLayout.spec(for: .peek, geometry: airM4, hasActivity: true, contentHeight: 70)
            == NotchLayout.spec(for: .peek, geometry: airM4, hasActivity: true))
    }

    @MainActor
    @Test func fileDragsGetTheFullHeight() {
        let model = NotchModel(geometry: airM4, showsIdleVirtualNotch: false)
        #expect(model.fittedContentHeight == nil)
        model.expandedContentHeight = 80
        #expect(model.fittedContentHeight == 80)
        model.isFileDragActive = true
        #expect(model.fittedContentHeight == nil)
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

struct FullScreenMonitorTests {
    let display = (id: CGDirectDisplayID(1), bounds: CGRect(x: 0, y: 0, width: 1710, height: 1112))
    let external = (id: CGDirectDisplayID(2), bounds: CGRect(x: 1710, y: 0, width: 2560, height: 1440))

    private func window(pid: Int32 = 42, layer: Int = 0, bounds: CGRect, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }

    @Test func fullScreenWindowCoversItsDisplay() {
        let covered = FullScreenMonitor.coveredDisplays(
            windows: [window(bounds: display.bounds)], displays: [display, external], ownPID: 1
        )
        #expect(covered == [1])
    }

    @Test func ordinaryAndOwnWindowsDontCount() {
        let covered = FullScreenMonitor.coveredDisplays(
            windows: [
                window(bounds: CGRect(x: 0, y: 25, width: 1710, height: 1087)), // maximized, below menu bar
                window(pid: 1, bounds: display.bounds), // Liova itself
                window(layer: -2_147_483_603, bounds: display.bounds), // desktop
                window(bounds: display.bounds, alpha: 0), // invisible
                window(layer: 25, bounds: display.bounds), // status-level overlay
            ],
            displays: [display, external], ownPID: 1
        )
        #expect(covered.isEmpty)
    }

    @Test func externalDisplayCanBeCoveredAlone() {
        let covered = FullScreenMonitor.coveredDisplays(
            windows: [window(bounds: external.bounds)], displays: [display, external], ownPID: 1
        )
        #expect(covered == [2])
    }
}

struct FileDragDetectorTests {
    @Test func fileDragIsRecognizedOnceTheDragSessionStarts() {
        var detector = FileDragDetector()
        detector.mouseDown(dragPasteboardChangeCount: 10)
        // Moving before the drag session writes the pasteboard: not decided yet.
        let early = detector.dragged(dragPasteboardChangeCount: 10) { true }
        let started = detector.dragged(dragPasteboardChangeCount: 11) { true }
        #expect(!early)
        #expect(started)
        #expect(detector.isFileDragActive)
        let ended = detector.mouseUp()
        #expect(ended)
        #expect(!detector.isFileDragActive)
    }

    @Test func nonFileDragsAreIgnoredForTheWholeDrag() {
        var detector = FileDragDetector()
        detector.mouseDown(dragPasteboardChangeCount: 3)
        let first = detector.dragged(dragPasteboardChangeCount: 4) { false }
        // Decided once per drag: later events don't re-check the pasteboard.
        var checked = false
        let later = detector.dragged(dragPasteboardChangeCount: 5) {
            checked = true
            return true
        }
        let ended = detector.mouseUp()
        #expect(!first)
        #expect(!later)
        #expect(!checked)
        #expect(!ended)
    }

    @Test func windowMovesAndSelectionsNeverCount() {
        var detector = FileDragDetector()
        detector.mouseDown(dragPasteboardChangeCount: 7)
        var any = false
        for _ in 0 ..< 20 {
            any = detector.dragged(dragPasteboardChangeCount: 7) { true } || any
        }
        let ended = detector.mouseUp()
        #expect(!any)
        #expect(!ended)
    }
}
