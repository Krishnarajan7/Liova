import Foundation
@testable import LiovaProviders
import Testing

/// Reads this Mac's real audio devices. Off unless `LIOVA_LIVE_TESTS=1`; plug in wired
/// headphones (USB-C EarPods, a USB headset or the jack) first:
///
///     LIOVA_LIVE_TESTS=1 swift test --filter WiredHeadphonesLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_LIVE_TESTS"] == "1"))
@MainActor
struct WiredHeadphonesLiveTests {
    @Test func seesPluggedInHeadphones() {
        let monitor = CoreAudioWiredHeadphonesMonitor()
        var received: [HeadphonesState] = []
        monitor.start { received = $0 }
        monitor.stop()
        print("Wired headphones:", received.map { "\($0.name) (\($0.kind), \($0.id))" })
        #expect(!received.isEmpty, "plug in wired headphones first")
        let allWired = received.allSatisfy(\.isWired)
        #expect(allWired)
    }
}
