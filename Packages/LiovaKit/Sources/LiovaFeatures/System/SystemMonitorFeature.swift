import Foundation
import LiovaCore
import LiovaProviders
import Observation

/// Live CPU, memory and GPU load for the System page, and the apps using the most of it.
///
/// Samples once a second (apps every other second), and only while the page is on screen
/// (on any display). When nobody is looking, it costs nothing.
@MainActor
@Observable
public final class SystemMonitorFeature {
    /// Most recent last. Up to `historyLength` samples.
    public private(set) var history: [SystemSample] = []

    public var latest: SystemSample? {
        history.last
    }

    /// Every app the user can quit, busiest first. Empty until the second reading.
    public private(set) var apps: [AppUsage] = []
    /// Which apps the page lists: the busiest processors or the biggest memory users.
    public var ranking = AppRanking.cpu
    /// Apps asked to quit, and when.
    public private(set) var quitRequests: [String: Date] = [:]

    public static let historyLength = 60
    public static let listedApps = 3
    static let interval: Duration = .seconds(1)
    /// Apps are read every this many samples: the list doesn't need to move every second.
    static let appsEvery = 2

    @ObservationIgnored private let reader: SystemMetricsReader
    @ObservationIgnored private let appReader: AppUsageReader
    @ObservationIgnored private let quitter: AppQuitter
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var samplingTask: Task<Void, Never>?

    public init(
        reader: SystemMetricsReader = SystemMetricsReader(),
        appReader: AppUsageReader = AppUsageReader(),
        quitter: AppQuitter = .system,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.appReader = appReader
        self.quitter = quitter
        self.now = now
    }

    /// The apps the page lists, in the chosen order.
    public var topApps: [AppUsage] {
        Array(ranking.sorted(apps).prefix(Self.listedApps))
    }

    public func quit(_ app: AppUsage) {
        quitter.quit(app)
        quitRequests[app.id] = now()
    }

    public func forceQuit(_ app: AppUsage) {
        quitter.forceQuit(app)
        quitRequests[app.id] = now()
    }

    /// Asked to quit and still running past `AppQuitter.patience` offers Force Quit.
    public func quitState(for app: AppUsage) -> QuitState {
        guard let asked = quitRequests[app.id] else { return .running }
        return now().timeIntervalSince(asked) >= AppQuitter.patience ? .notResponding : .quitting
    }

    /// Call when a System page appears; balance with `viewerLeft()`.
    public func viewerAppeared() {
        viewers += 1
        guard samplingTask == nil else { return }
        let reader = reader
        let appReader = appReader
        samplingTask = Task { [weak self] in
            // Prime the CPU baselines. Off the main thread: the GPU read goes through IOKit,
            // and the page shouldn't wait on the driver to open.
            await Task.detached(priority: .utility) {
                _ = reader.sample()
                _ = appReader.sample()
            }.value
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval, tolerance: .milliseconds(200))
                guard !Task.isCancelled else { return }
                tick += 1
                let readsApps = tick % Self.appsEvery == 0
                let (sample, apps) = await Task.detached(priority: .utility) {
                    (reader.sample(), readsApps ? appReader.sample() : nil)
                }.value
                self?.append(sample)
                if let apps {
                    self?.update(apps)
                }
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

    func update(_ apps: [AppUsage]) {
        self.apps = apps
        // Forget apps that quit; one that comes back starts fresh.
        quitRequests = quitRequests.filter { request in apps.contains { $0.id == request.key } }
    }

    func append(_ sample: SystemSample) {
        history.append(sample)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}

/// How the System page orders apps.
public enum AppRanking: String, CaseIterable, Sendable {
    case cpu, memory

    func sorted(_ apps: [AppUsage]) -> [AppUsage] {
        switch self {
        case .cpu: apps // already busiest first
        case .memory: apps.sorted { ($0.memory, $0.cpu) > ($1.memory, $1.cpu) }
        }
    }
}

/// Where an app is in being quit.
public enum QuitState: Equatable, Sendable {
    case running
    /// Asked to quit; it may be showing a "save changes?" sheet.
    case quitting
    /// Still running a while after being asked: offer Force Quit.
    case notResponding
}

/// Quits apps. A value so tests can swap in a recorder.
public struct AppQuitter: Sendable {
    public var quit: @MainActor @Sendable (AppUsage) -> Void
    public var forceQuit: @MainActor @Sendable (AppUsage) -> Void

    /// How long an app gets to quit before Force Quit is offered.
    public static let patience: TimeInterval = 3

    public init(
        quit: @escaping @MainActor @Sendable (AppUsage) -> Void,
        forceQuit: @escaping @MainActor @Sendable (AppUsage) -> Void
    ) {
        self.quit = quit
        self.forceQuit = forceQuit
    }

    public static let system = AppQuitter(
        quit: { AppTerminator.quit($0) },
        forceQuit: { AppTerminator.forceQuit($0) }
    )
}
