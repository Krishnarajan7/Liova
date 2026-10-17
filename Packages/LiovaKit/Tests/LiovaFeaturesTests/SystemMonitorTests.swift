@testable import LiovaFeatures
import LiovaProviders
import Testing

@MainActor
struct SystemMonitorTests {
    @Test func samplesOnlyWhileSomeoneIsLooking() {
        let feature = SystemMonitorFeature()
        #expect(!feature.isSampling)
        feature.viewerAppeared()
        feature.viewerAppeared() // a second display
        #expect(feature.isSampling)
        feature.viewerLeft()
        #expect(feature.isSampling)
        feature.viewerLeft()
        #expect(!feature.isSampling)
        feature.viewerLeft() // unbalanced extra call is harmless
        #expect(!feature.isSampling)
    }

    @Test func historyIsCapped() {
        let feature = SystemMonitorFeature()
        for index in 0 ..< 100 {
            feature.append(SystemSample(cpu: Double(index) / 100, memory: 0.5, gpu: nil))
        }
        #expect(feature.history.count == SystemMonitorFeature.historyLength)
        #expect(feature.latest?.cpu == 0.99)
    }
}
