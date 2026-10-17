import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// Live CPU, memory and GPU load for the System page.
///
/// Samples once a second, and only while the page is on screen (on any display). When
/// nobody is looking, it costs nothing.
@MainActor
@Observable
public final class SystemMonitorFeature {
    /// Most recent last. Up to `historyLength` samples.
    public private(set) var history: [SystemSample] = []

    public var latest: SystemSample? {
        history.last
    }

    public static let historyLength = 60
    static let interval: Duration = .seconds(1)

    @ObservationIgnored private let reader: SystemMetricsReader
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var samplingTask: Task<Void, Never>?

    public init(reader: SystemMetricsReader = SystemMetricsReader()) {
        self.reader = reader
    }

    /// Call when a System page appears; balance with `viewerLeft()`.
    public func viewerAppeared() {
        viewers += 1
        guard samplingTask == nil else { return }
        let reader = reader
        _ = reader.sample() // prime the CPU tick baseline
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval, tolerance: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let sample = await Task.detached(priority: .utility) { reader.sample() }.value
                self?.append(sample)
            }
        }
    }

    public func viewerLeft() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        samplingTask?.cancel()
        samplingTask = nil
    }

    public var isSampling: Bool {
        samplingTask != nil
    }

    func append(_ sample: SystemSample) {
        history.append(sample)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}
