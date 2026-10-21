import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

private let page = URL(string: "https://github.com/Krishnarajan7/Liova/releases/tag/v0.2.0")!

private func release(_ version: String, beta: Bool = false, installer: Bool = true) -> ReleaseInfo {
    let file = URL(string: "https://github.com/Krishnarajan7/Liova/releases/download/v\(version)/Liova-\(version).dmg")!
    return ReleaseInfo(
        version: AppVersion(version)!,
        name: "Liova \(version)",
        notes: "- Better",
        pageURL: page,
        isPrerelease: beta,
        installer: installer ? .init(name: "Liova-\(version).dmg", url: file, size: 1000) : nil,
        checksum: .init(name: "Liova-\(version).dmg.sha256", url: file, size: 80)
    )
}

private final class FakeReleases: ReleaseFetching, @unchecked Sendable {
    var answer: Result<[ReleaseInfo], any Error>
    private(set) var calls = 0

    init(_ releases: [ReleaseInfo]) {
        answer = .success(releases)
    }

    func releases() async throws -> [ReleaseInfo] {
        calls += 1
        return try answer.get()
    }
}

private final class FakeInstaller: UpdateInstalling, @unchecked Sendable {
    var support: UpdateInstaller.InPlaceSupport = .supported
    var downloadResult: Result<URL, UpdateInstaller.Failure> = .success(URL(filePath: "/tmp/Liova-0.2.0.dmg"))
    var prepareResult: Result<URL, UpdateInstaller.Failure> = .success(URL(filePath: "/tmp/staged/Liova.app"))
    private(set) var steps: [String] = []

    func inPlaceSupport(for _: URL) -> UpdateInstaller.InPlaceSupport {
        support
    }

    func download(
        _ release: ReleaseInfo,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(UpdateInstaller.Failure) -> URL {
        steps.append("download \(release.version)")
        progress(0.5)
        return try downloadResult.get()
    }

    func prepare(
        installer _: URL,
        release: ReleaseInfo,
        replacing _: URL
    ) async throws(UpdateInstaller.Failure) -> URL {
        steps.append("prepare \(release.version)")
        return try prepareResult.get()
    }

    func installAfterQuit(staged: URL, replacing currentApp: URL) throws(UpdateInstaller.Failure) {
        steps.append("install \(staged.path) -> \(currentApp.path)")
    }
}

@MainActor
struct UpdatePolicyTests {
    private let current = AppVersion("0.1.0")!

    @Test func offersTheNewestReleaseWithAnInstaller() {
        let releases = [release("0.1.0"), release("0.3.0", installer: false), release("0.2.1"), release("0.2.0")]
        #expect(UpdatePolicy.newest(in: releases, above: current, includingBetas: false)?
            .version == AppVersion("0.2.1"))
    }

    @Test func betasOnlyWhenAskedFor() {
        let releases = [release("0.2.0"), release("0.3.0-beta.1", beta: true)]
        #expect(UpdatePolicy.newest(in: releases, above: current, includingBetas: false)?
            .version == AppVersion("0.2.0"))
        #expect(UpdatePolicy.newest(in: releases, above: current, includingBetas: true)?.version
            == AppVersion("0.3.0-beta.1"))
    }

    @Test func nothingWhenUpToDate() {
        #expect(UpdatePolicy.newest(in: [release("0.1.0")], above: current, includingBetas: true) == nil)
        #expect(UpdatePolicy.newest(in: [], above: current, includingBetas: true) == nil)
    }

    @Test func dueOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdatePolicy.isDue(lastCheck: nil, now: now))
        #expect(!UpdatePolicy.isDue(lastCheck: now - 3600, now: now))
        #expect(UpdatePolicy.isDue(lastCheck: now - 24 * 3600, now: now))
        #expect(UpdatePolicy.isDue(lastCheck: now + 3600, now: now)) // clock moved back
    }

    @Test func announcesOncePerVersionUnlessSkipped() {
        let new = release("0.2.0")
        #expect(UpdatePolicy.shouldAnnounce(new, skipped: nil, alreadyAnnounced: nil))
        #expect(!UpdatePolicy.shouldAnnounce(new, skipped: "0.2.0", alreadyAnnounced: nil))
        #expect(!UpdatePolicy.shouldAnnounce(new, skipped: nil, alreadyAnnounced: AppVersion("0.2.0")))
        #expect(UpdatePolicy.shouldAnnounce(release("0.3.0"), skipped: "0.2.0", alreadyAnnounced: AppVersion("0.2.0")))
    }
}

@MainActor
struct UpdateFeatureTests {
    private let engine = ActivityEngine()
    private let scratch = ScratchDefaults()
    private let settings: LiovaSettings
    private let appURL = URL(filePath: "/Applications/Liova.app")

    init() {
        settings = LiovaSettings(defaults: scratch.defaults)
    }

    private final class Recorder {
        var quits = 0
        var opened: [URL] = []
    }

    private func feature(
        _ fetcher: FakeReleases,
        _ installer: FakeInstaller = FakeInstaller(),
        recorder: Recorder = Recorder()
    ) -> UpdateFeature {
        UpdateFeature(
            engine: engine,
            settings: settings,
            fetcher: fetcher,
            installer: installer,
            appURL: appURL,
            currentVersion: AppVersion("0.1.0"),
            quit: { recorder.quits += 1 },
            openFile: { recorder.opened.append($0) }
        )
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    @Test func checksByThemselvesByDefault() {
        #expect(settings.automaticUpdateChecks)
        #expect(!settings.betaUpdates)
    }

    @Test func findsAnUpdateAndSaysSoOnce() async throws {
        let updates = feature(FakeReleases([release("0.2.0")]))
        updates.check(isManual: false)
        try await settle()
        #expect(updates.status == .available(release("0.2.0")))
        #expect(updates.availableRelease?.version == AppVersion("0.2.0"))
        #expect(engine.activity(UpdatePolicy.activityID)?.title == "Liova 0.2.0 is available")
        #expect(settings.lastUpdateCheck != nil)

        engine.end(UpdatePolicy.activityID)
        updates.check(isManual: false)
        try await settle()
        #expect(engine.activity(UpdatePolicy.activityID) == nil)
    }

    @Test func upToDate() async throws {
        let updates = feature(FakeReleases([release("0.1.0")]))
        updates.checkNow()
        try await settle()
        #expect(updates.status == .upToDate)
        #expect(updates.availableRelease == nil)
    }

    @Test func skippedVersionsStayQuietUntilAskedFor() async throws {
        let updates = feature(FakeReleases([release("0.2.0")]))
        settings.skippedUpdateVersion = "0.2.0"
        updates.check(isManual: false)
        try await settle()
        #expect(updates.status == .upToDate)
        #expect(engine.activity(UpdatePolicy.activityID) == nil)

        updates.checkNow()
        try await settle()
        #expect(updates.availableRelease?.version == AppVersion("0.2.0"))
        #expect(engine.activity(UpdatePolicy.activityID) == nil)
    }

    @Test func skipping() async throws {
        let updates = feature(FakeReleases([release("0.2.0")]))
        updates.checkNow()
        try await settle()
        updates.skip()
        #expect(settings.skippedUpdateVersion == "0.2.0")
        #expect(updates.status == .upToDate)
        #expect(engine.activity(UpdatePolicy.activityID) == nil)
    }

    @Test func offlineIsQuietUnlessAsked() async throws {
        let fetcher = FakeReleases([])
        fetcher.answer = .failure(URLError(.notConnectedToInternet))
        let updates = feature(fetcher)
        updates.check(isManual: false)
        try await settle()
        #expect(updates.status == .idle)
        updates.checkNow()
        try await settle()
        #expect(updates.status == .failed(nil, message: "Couldn't reach GitHub to check for updates."))
    }

    @Test func anOfferSurvivesAFailedRecheck() async throws {
        let fetcher = FakeReleases([release("0.2.0")])
        let updates = feature(fetcher)
        updates.checkNow()
        try await settle()
        fetcher.answer = .failure(URLError(.timedOut))
        updates.checkNow()
        try await settle()
        #expect(updates.status == .available(release("0.2.0")))
    }

    @Test func installsInPlaceThenQuits() async throws {
        let installer = FakeInstaller()
        let recorder = Recorder()
        let updates = feature(FakeReleases([release("0.2.0")]), installer, recorder: recorder)
        updates.checkNow()
        try await settle()
        updates.install()
        #expect(updates.status.isBusy)
        #expect(engine.activity(UpdatePolicy.activityID)?.progress == 0)
        try await settle()
        #expect(installer.steps == [
            "download 0.2.0", "prepare 0.2.0", "install /tmp/staged/Liova.app -> /Applications/Liova.app",
        ])
        #expect(updates.status == .installing(release("0.2.0")))
        #expect(recorder.quits == 1)
        #expect(recorder.opened.isEmpty)
    }

    @Test func aCopyThatCantReplaceItselfOpensTheInstaller() async throws {
        let installer = FakeInstaller()
        installer.support = .adHocBuild
        let recorder = Recorder()
        let updates = feature(FakeReleases([release("0.2.0")]), installer, recorder: recorder)
        #expect(updates.inPlaceSupport == .adHocBuild)
        updates.checkNow()
        try await settle()
        updates.install()
        try await settle()
        #expect(installer.steps == ["download 0.2.0"])
        #expect(recorder.opened == [URL(filePath: "/tmp/Liova-0.2.0.dmg")])
        #expect(recorder.quits == 0)
        #expect(updates.status == .openedInstaller(release("0.2.0")))
        #expect(engine.activity(UpdatePolicy.activityID) == nil)
    }

    @Test func aRejectedSignatureStopsTheUpdate() async throws {
        let installer = FakeInstaller()
        installer.prepareResult = .failure(.signatureMismatch)
        let recorder = Recorder()
        let updates = feature(FakeReleases([release("0.2.0")]), installer, recorder: recorder)
        updates.checkNow()
        try await settle()
        updates.install()
        try await settle()
        #expect(installer.steps == ["download 0.2.0", "prepare 0.2.0"])
        #expect(recorder.quits == 0)
        #expect(updates.status == .failed(release("0.2.0"), message: UpdateInstaller.Failure.signatureMismatch.message))
        #expect(engine.activity(UpdatePolicy.activityID) == nil)
        // Still on offer, so it can be tried again.
        #expect(updates.availableRelease?.version == AppVersion("0.2.0"))
    }

    @Test func turningChecksOffStopsTheSchedule() {
        let updates = feature(FakeReleases([]))
        settings.automaticUpdateChecks = false
        updates.syncWithSettings()
        updates.stop()
        #expect(updates.status == .idle)
    }
}
