import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

private let now = Date(timeIntervalSince1970: 3_000_000)

private func download(
    _ id: String = "partial-1",
    name: String = "Movie.mkv",
    completed: Int64 = 412_000_000,
    total: Int64? = 1_400_000_000,
    rate: Double? = 8_300_000,
    remaining: TimeInterval? = 118,
    state: DownloadItem.State = .active
) -> DownloadItem {
    DownloadItem(
        id: id, displayName: name, sourceApp: "Safari", bytesCompleted: completed, totalBytes: total,
        throughput: rate, estimatedTimeRemaining: remaining, state: state, startDate: now, lastChangeDate: now
    )
}

private func started(_ actions: [DownloadsPolicy.Action]) -> [Activity] {
    actions.compactMap {
        if case let .start(activity) = $0 {
            activity
        } else {
            nil
        }
    }
}

private func ended(_ actions: [DownloadsPolicy.Action]) -> [ActivityID] {
    actions.compactMap {
        if case let .end(id) = $0 {
            id
        } else {
            nil
        }
    }
}

struct DownloadsPolicyTests {
    @Test func activeDownloadActivity() throws {
        let activity = try #require(started(DownloadsPolicy.actions(items: [download()], shown: [], now: now)).first)
        #expect(activity.id == "system.downloads.partial-1")
        #expect(activity.source == "system.downloads")
        #expect(activity.priority == .low)
        #expect(activity.title == "Movie.mkv")
        #expect(activity.symbol == "arrow.down.circle")
        #expect(activity.tint == .blue)
        #expect(activity.progress == 0.29)
        #expect(activity.expiresAt == nil)
        let expected = "\(DownloadsFormat.bytes(412_000_000)) of \(DownloadsFormat.bytes(1_400_000_000))"
            + " · \(DownloadsFormat.speed(8_300_000)) · 2 min left"
        #expect(activity.subtitle == expected)
    }

    @Test func unknownTotalHasNoProgressOrTimeLeft() throws {
        let item = download(total: nil, remaining: 30)
        let activity = try #require(started(DownloadsPolicy.actions(items: [item], shown: [], now: now)).first)
        #expect(activity.progress == nil)
        #expect(activity.subtitle == "\(DownloadsFormat.bytes(412_000_000)) · \(DownloadsFormat.speed(8_300_000))")
    }

    @Test func noSpeedYetShowsBytesOnly() {
        let text = DownloadsPolicy.subtitle(completed: 5_000_000, total: nil, throughput: nil, remaining: nil)
        #expect(text == DownloadsFormat.bytes(5_000_000))
    }

    @Test func progressIsRoundedSoTinyTicksDontRepublish() {
        let first = started(DownloadsPolicy.actions(
            items: [download(completed: 500_000_000, total: 1_000_000_000, rate: nil)], shown: [], now: now
        ))
        let second = started(DownloadsPolicy.actions(
            items: [download(completed: 500_400_000, total: 1_000_000_000, rate: nil)], shown: [], now: now
        ))
        #expect(first.first?.progress == 0.5)
        #expect(second.first?.progress == 0.5)
    }

    @Test func idsAreSanitized() {
        #expect(DownloadsPolicy.activityID(for: "a/b c.d") == "system.downloads.a-b-c-d")
        #expect(DownloadsPolicy.activityID(for: "") == "system.downloads.unknown")
        #expect(DownloadsPolicy.activityID(for: String(repeating: "x", count: 300)).rawValue.count
            == "system.downloads.".count + 64)
    }

    @Test func upToThreeAreShownSeparately() {
        let items = (1 ... 3).map { download("d\($0)", name: "File \($0)") }
        let activities = started(DownloadsPolicy.actions(items: items, shown: [], now: now))
        #expect(activities.map(\.title) == ["File 1", "File 2", "File 3"])
    }

    @Test func moreThanThreeCombine() throws {
        let items = (1 ... 4).map { download("d\($0)", completed: 100_000_000, total: 400_000_000, rate: 1_000_000) }
        let shown: Set<ActivityID> = ["system.downloads.d1", "system.downloads.d2", "system.downloads.d3"]
        let actions = DownloadsPolicy.actions(items: items, shown: shown, now: now)
        #expect(Set(ended(actions)) == shown)
        let combined = try #require(started(actions).first)
        #expect(started(actions).count == 1)
        #expect(combined.id == DownloadsPolicy.combinedID)
        #expect(combined.title == "4 downloads")
        #expect(combined.progress == 0.25)
        #expect(combined.subtitle?.contains(DownloadsFormat.speed(4_000_000)) == true)
    }

    @Test func combinedWithAnUnknownTotalHasNoProgress() throws {
        var items = (1 ... 4).map { download("d\($0)") }
        items[2].totalBytes = nil
        let combined = try #require(started(DownloadsPolicy.actions(items: items, shown: [], now: now)).first)
        #expect(combined.progress == nil)
    }

    @Test func finishingEndsTheDownloadAndFlashes() throws {
        let done = download(state: .finished)
        let actions = DownloadsPolicy.actions(items: [done], shown: ["system.downloads.partial-1"], now: now)
        #expect(ended(actions) == ["system.downloads.partial-1"])
        let flash = try #require(started(actions).first)
        #expect(flash.id == DownloadsPolicy.finishedID)
        #expect(flash.priority == .high)
        #expect(flash.title == "Movie.mkv")
        #expect(flash.symbol == "checkmark.circle.fill")
        #expect(flash.tint == .green)
        #expect(flash.expiresAt == now + 4)
    }

    @Test func severalFinishingAtOnceFlashOnce() {
        let actions = DownloadsPolicy.actions(
            items: [download("a", state: .finished), download("b", state: .finished)], shown: [], now: now
        )
        #expect(started(actions).map(\.title) == ["2 downloads"])
    }

    @Test func failingEndsQuietly() {
        let actions = DownloadsPolicy.actions(
            items: [download(state: .failed)], shown: ["system.downloads.partial-1"], now: now
        )
        #expect(actions == [.end("system.downloads.partial-1")])
    }

    @Test(arguments: [
        (3.0, "5 s left"), (42, "45 s left"), (59.5, "55 s left"), (60, "1 min left"), (61, "2 min left"),
        (3600, "1 hr left"), (3900, "1 hr 5 min left"),
    ])
    func timeRemaining(seconds: Double, text: String) {
        #expect(DownloadsFormat.timeRemaining(seconds) == text)
    }

    @Test func nonsenseTimesAreHidden() {
        #expect(DownloadsFormat.timeRemaining(-1) == nil)
        #expect(DownloadsFormat.timeRemaining(.infinity) == nil)
        #expect(DownloadsFormat.timeRemaining(30 * 24 * 3600) == nil)
    }

    @Test(arguments: [
        (8_300_000.0, "8.3M/s"), (12_400_000, "12M/s"), (412_000, "412K/s"), (999_999, "1.0M/s"),
        (1_500_000_000, "1.5G/s"), (500, "<1K/s"), (0, "0K/s"),
    ])
    func compactSpeed(rate: Double, text: String) {
        #expect(DownloadsFormat.compactSpeed(rate) == text)
    }

    @Test func compactBytes() {
        #expect(DownloadsFormat.compactBytes(412_000_000) == "412M")
        #expect(DownloadsFormat.compactBytes(1_400_000_000) == "1.4G")
    }
}

@MainActor
final class FakeDownloads: DownloadSourcing {
    private var onChange: (@MainActor ([DownloadItem]) -> Void)?
    private(set) var isStarted = false

    func start(onChange: @escaping @MainActor ([DownloadItem]) -> Void) {
        isStarted = true
        self.onChange = onChange
    }

    func stop() {
        isStarted = false
        onChange = nil
    }

    func send(_ items: [DownloadItem]) {
        onChange?(items)
    }
}

@MainActor
struct DownloadsFeatureTests {
    let engine = ActivityEngine(now: { now })
    let settings: LiovaSettings
    let source = FakeDownloads()

    init() throws {
        settings = try LiovaSettings(defaults: #require(UserDefaults(suiteName: "app.liova.tests.\(UUID())")))
    }

    private func makeFeature() -> DownloadsFeature {
        DownloadsFeature(engine: engine, settings: settings, source: source, now: { now })
    }

    @Test func activeDownloadsReachTheEngineAndTheStore() {
        let feature = makeFeature()
        feature.start()
        source.send([download()])
        #expect(engine.current?.title == "Movie.mkv")
        #expect(feature.items.map(\.id) == ["partial-1"])
        #expect(feature.item(for: "system.downloads.partial-1")?.displayName == "Movie.mkv")
    }

    @Test func updatesInPlaceAndFinishWithAFlash() {
        let feature = makeFeature()
        feature.start()
        source.send([download()])
        source.send([download(completed: 900_000_000)])
        #expect(engine.activities.count == 1)
        #expect(engine.current?.progress == 0.64)
        source.send([download(completed: 1_400_000_000, state: .finished)])
        #expect(engine.activities.map(\.id) == [DownloadsPolicy.finishedID])
        #expect(feature.items.isEmpty)
    }

    @Test func aDownloadThatDisappearsEndsQuietly() {
        let feature = makeFeature()
        feature.start()
        source.send([download("a"), download("b")])
        source.send([download("b")])
        #expect(engine.activities.map(\.id) == ["system.downloads.b"])
    }

    @Test func collapsingAndExpandingAgainLeavesNoStrays() {
        let feature = makeFeature()
        feature.start()
        let four = (1 ... 4).map { download("d\($0)") }
        source.send(four)
        #expect(engine.activities.map(\.id) == [DownloadsPolicy.combinedID])
        source.send(Array(four.prefix(2)))
        #expect(Set(engine.activities.map(\.id)) == ["system.downloads.d1", "system.downloads.d2"])
    }

    @Test func disablingInSettingsStopsAndClears() {
        let feature = makeFeature()
        feature.syncWithSettings()
        #expect(source.isStarted)
        source.send([download()])
        settings.downloadsEnabled = false
        feature.syncWithSettings()
        #expect(!source.isStarted)
        #expect(engine.activities.isEmpty)
        #expect(feature.items.isEmpty)
    }

    @Test func deliveriesAfterStopAreIgnored() {
        let feature = makeFeature()
        feature.start()
        let deliver = source
        feature.stop()
        deliver.send([download()])
        #expect(engine.activities.isEmpty)
    }
}
