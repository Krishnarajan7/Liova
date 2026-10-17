@testable import LiovaProviders
import Testing

struct SystemMetricsTests {
    @Test func loadIsTheBusyShareOfNewTicks() {
        #expect(SystemMetricsReader.load(from: (busy: 100, total: 1000), to: (busy: 150, total: 1100)) == 0.5)
    }

    @Test func loadHandlesCounterResetsAndIdleIntervals() {
        #expect(SystemMetricsReader.load(from: (busy: 500, total: 1000), to: (busy: 10, total: 20)) == 0)
        #expect(SystemMetricsReader.load(from: (busy: 5, total: 10), to: (busy: 5, total: 10)) == 0)
    }

    @Test func readsThisMacWithinRange() async throws {
        let reader = SystemMetricsReader()
        _ = reader.sample()
        try await Task.sleep(for: .milliseconds(200))
        let sample = reader.sample()
        #expect((0 ... 1).contains(sample.cpu))
        #expect(sample.memory > 0 && sample.memory <= 1)
        if let gpu = sample.gpu {
            #expect((0 ... 1).contains(gpu))
        }
    }
}
