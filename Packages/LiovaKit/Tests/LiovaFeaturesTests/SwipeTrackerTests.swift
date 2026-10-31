import CoreGraphics
@testable import LiovaFeatures
import Testing

struct SwipeTrackerTests {
    /// One gesture of `steps` equal moves; returns every swipe it produced.
    private func swipe(
        _ tracker: inout SwipeTracker,
        dx sideways: CGFloat,
        dy vertical: CGFloat = 0,
        steps: Int = 10,
        inverted: Bool = true
    ) -> [SwipeDirection] {
        (0 ..< steps).compactMap { step in
            tracker.add(
                deltaX: sideways, deltaY: vertical, inverted: inverted, began: step == 0, ended: step == steps - 1
            )
        }
    }

    @Test func fingersRightIsNextWithNaturalScrolling() {
        var tracker = SwipeTracker()
        // Natural scrolling: fingers moving right give a negative horizontal delta.
        #expect(swipe(&tracker, dx: -10) == [.right])
    }

    @Test func fingersRightIsNextWithoutNaturalScrollingToo() {
        var tracker = SwipeTracker()
        #expect(swipe(&tracker, dx: 10, inverted: false) == [.right])
        #expect(swipe(&tracker, dx: -10, inverted: false) == [.left])
    }

    @Test func oneSwipePerGestureHoweverFar() {
        var tracker = SwipeTracker()
        #expect(swipe(&tracker, dx: 40, steps: 20) == [.left])
    }

    @Test func aShortNudgeIsNothing() {
        var tracker = SwipeTracker()
        #expect(swipe(&tracker, dx: 4).isEmpty)
    }

    @Test func scrollingUpOrDownNeverSkipsASong() {
        var tracker = SwipeTracker()
        #expect(swipe(&tracker, dx: 8, dy: 15).isEmpty)
    }

    @Test func eachGestureStartsFresh() {
        var tracker = SwipeTracker()
        #expect(swipe(&tracker, dx: -10) == [.right])
        #expect(swipe(&tracker, dx: 10) == [.left])
    }
}
