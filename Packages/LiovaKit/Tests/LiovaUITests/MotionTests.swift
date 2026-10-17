import LiovaUI
import SwiftUI
import Testing

@MainActor
@Test func withoutAnimationRunsBodySynchronously() {
    var ran = false
    Motion.withoutAnimation { ran = true }
    #expect(ran)
}
