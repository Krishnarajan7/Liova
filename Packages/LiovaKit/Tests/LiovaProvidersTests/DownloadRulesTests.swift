import Foundation
@testable import LiovaProviders
import Testing

struct DownloadClassificationTests {
    @Test(arguments: [
        ("Movie.mkv.crdownload", "Movie.mkv"),
        ("archive.tar.gz.part", "archive.tar.gz"),
        ("Report.pdf.download", "Report.pdf"),
        ("video.mp4.partial", "video.mp4"),
        ("setup.dmg.opdownload", "setup.dmg"),
        ("telegram-cloud-document-2-123_partial", "telegram-cloud-document-2-123"),
        ("Photo.JPG.CRDOWNLOAD", "Photo.JPG"),
    ])
    func finalNameStripsThePartialSuffix(partial: String, final: String) {
        #expect(PartialFileRules.finalName(forPartialName: partial) == final)
    }

    @Test(arguments: ["Movie.mkv", "notes.txt", ".crdownload", ".hidden.part", "_partial", "README", "a..part"])
    func ordinaryNamesAreNotDownloads(name: String) {
        #expect(PartialFileRules.finalName(forPartialName: name) == nil)
    }

    @Test func chromeDownloadInDownloads() throws {
        let result = try #require(PartialFileRules.classify(
            path: "/Users/me/Downloads/Movie.mkv.crdownload", rootKind: .downloads
        ))
        #expect(result.trackedPath == "/Users/me/Downloads/Movie.mkv.crdownload")
        #expect(result.displayName == "Movie.mkv")
        #expect(result.finalPath == "/Users/me/Downloads/Movie.mkv")
        #expect(result.sourceApp == nil)
        #expect(!result.isBundle)
    }

    @Test func safariBundleIsTrackedAsAWholeFromAnyFileInside() throws {
        let result = try #require(PartialFileRules.classify(
            path: "/Users/me/Downloads/Talk.mov.download/Talk.mov", rootKind: .downloads
        ))
        #expect(result.trackedPath == "/Users/me/Downloads/Talk.mov.download")
        #expect(result.displayName == "Talk.mov")
        #expect(result.sourceApp == "Safari")
        #expect(result.isBundle)
        #expect(result.finalPath == "/Users/me/Downloads/Talk.mov")
    }

    @Test func telegramDesktopFolderNamesTheApp() throws {
        let result = try #require(PartialFileRules.classify(
            path: "/Users/me/Downloads/Telegram Desktop/clip.mp4.part", rootKind: .downloads
        ))
        #expect(result.sourceApp == "Telegram")
        #expect(result.displayName == "clip.mp4")
    }

    @Test func chromeUnconfirmedHasNoKnownFinalName() throws {
        let result = try #require(PartialFileRules.classify(
            path: "/Users/me/Downloads/Unconfirmed 482913.crdownload", rootKind: .downloads
        ))
        #expect(result.displayName == "Download")
        #expect(result.finalPath == nil)
    }

    @Test func telegramMediaPartialHasNoNameOrSize() throws {
        let path = "/c/stable/account-1/postbox/media/telegram-cloud-document-2-55_partial"
        let result = try #require(PartialFileRules.classify(path: path, rootKind: .telegramMedia))
        #expect(result.displayName == "Telegram download")
        #expect(result.sourceApp == "Telegram")
        #expect(result.finalPath == "/c/stable/account-1/postbox/media/telegram-cloud-document-2-55")
        #expect(!result.finalNameIsMeaningful)
    }

    @Test(arguments: [
        "/c/stable/account-1/postbox/db/db_sqlite",
        "/c/stable/account-1/postbox/media/telegram-cloud-document-2-55",
        "/c/stable/account-1/postbox/media/movie.mkv.part",
        "/c/stable/account-1/other/x_partial",
    ])
    func telegramIgnoresEverythingElse(path: String) {
        #expect(PartialFileRules.classify(path: path, rootKind: .telegramMedia) == nil)
    }

    @Test func downloadsIgnoresFinishedAndHiddenFiles() {
        #expect(PartialFileRules.classify(path: "/d/Movie.mkv", rootKind: .downloads) == nil)
        #expect(PartialFileRules.classify(path: "/d/.com.google.Chrome.x.crdownload", rootKind: .downloads) == nil)
    }
}

struct ThroughputEstimatorTests {
    let start = Date(timeIntervalSince1970: 1000)

    @Test func needsTwoSamples() {
        var estimator = ThroughputEstimator()
        estimator.add(bytes: 0, at: start)
        #expect(estimator.bytesPerSecond == nil)
        estimator.add(bytes: 1_000_000, at: start + 1)
        #expect(estimator.bytesPerSecond == 1_000_000)
    }

    @Test func smoothsTowardTheNewRate() throws {
        var estimator = ThroughputEstimator(timeConstant: 3)
        estimator.add(bytes: 0, at: start)
        estimator.add(bytes: 1_000_000, at: start + 1)
        estimator.add(bytes: 4_000_000, at: start + 2) // jumps to 3 MB/s
        let rate = try #require(estimator.bytesPerSecond)
        let alpha = 1 - exp(-1.0 / 3)
        #expect(abs(rate - (1_000_000 + alpha * 2_000_000)) < 1)
        #expect(rate > 1_000_000 && rate < 3_000_000)
    }

    @Test func unevenSpacingIsWeightedByTime() throws {
        var short = ThroughputEstimator(timeConstant: 3)
        var long = ThroughputEstimator(timeConstant: 3)
        short.add(bytes: 0, at: start)
        short.add(bytes: 1_000_000, at: start + 1)
        short.add(bytes: 1_500_000, at: start + 1.5) // 1 MB/s, half a second later
        long.add(bytes: 0, at: start)
        long.add(bytes: 1_000_000, at: start + 1)
        long.add(bytes: 1_000_000, at: start + 4) // stalled 3 s
        #expect(try #require(short.bytesPerSecond) == 1_000_000)
        #expect(try #require(long.bytesPerSecond) < 400_000)
    }

    @Test func samplesTooCloseTogetherAreMerged() {
        var estimator = ThroughputEstimator(minimumInterval: 0.2)
        estimator.add(bytes: 0, at: start)
        estimator.add(bytes: 500, at: start + 0.05)
        #expect(estimator.bytesPerSecond == nil)
        estimator.add(bytes: 2000, at: start + 1)
        #expect(estimator.bytesPerSecond == 2000)
    }

    @Test func shrinkingResets() {
        var estimator = ThroughputEstimator()
        estimator.add(bytes: 0, at: start)
        estimator.add(bytes: 5_000_000, at: start + 1)
        estimator.add(bytes: 100, at: start + 2)
        #expect(estimator.bytesPerSecond == nil)
    }

    @Test func decayedRateIsHiddenAndTimeRemainingNeedsATotal() {
        var estimator = ThroughputEstimator()
        estimator.add(bytes: 0, at: start)
        estimator.add(bytes: 500, at: start + 1)
        #expect(estimator.displayRate == nil)
        estimator.add(bytes: 2_000_500, at: start + 2)
        #expect(estimator.timeRemaining(completed: 2_000_500, total: nil) == nil)
        #expect(estimator.timeRemaining(completed: 2_000_500, total: 2_000_000) == nil)
        #expect(estimator.timeRemaining(completed: 2_000_500, total: 4_000_500).map { $0 > 0 } == true)
    }
}

struct PartialDownloadTrackerTests {
    let start = Date(timeIntervalSince1970: 1000)
    let chrome = PartialFileRules.classify(path: "/d/Movie.mkv.crdownload", rootKind: .downloads)!

    @Test func becomesVisibleOnceGrownBigAndOldEnough() {
        var tracker = PartialDownloadTracker()
        tracker.observe(chrome, size: 0, at: start)
        #expect(tracker.drain().isEmpty)
        tracker.observe(chrome, size: 3_000_000, at: start + 1)
        #expect(tracker.drain().isEmpty) // only 1 s old
        tracker.observe(chrome, size: 6_000_000, at: start + 2)
        let items = tracker.drain()
        #expect(items.count == 1)
        #expect(items.first?.displayName == "Movie.mkv")
        #expect(items.first?.bytesCompleted == 6_000_000)
        #expect(items.first?.state == .active)
        #expect(items.first?.totalBytes == nil)
        #expect(items.first?.throughput != nil)
    }

    @Test func smallFilesStayHidden() {
        var tracker = PartialDownloadTracker()
        tracker.observe(chrome, size: 0, at: start)
        tracker.observe(chrome, size: 400_000, at: start + 3)
        #expect(tracker.drain().isEmpty)
        #expect(!tracker.isEmpty) // still watched in case it grows
    }

    @Test func aFileThatNeverGrowsIsNotADownload() {
        var tracker = PartialDownloadTracker()
        tracker.observe(chrome, size: 50_000_000, at: start)
        tracker.observe(chrome, size: 50_000_000, at: start + 5)
        #expect(tracker.drain().isEmpty)
    }

    @Test func quickDownloadsAreDroppedQuietly() {
        var tracker = PartialDownloadTracker()
        tracker.observe(chrome, size: 0, at: start)
        tracker.observe(chrome, size: 9_000_000, at: start + 1)
        tracker.vanished(path: chrome.trackedPath, finalPath: "/d/Movie.mkv", at: start + 1.5)
        #expect(tracker.drain().isEmpty)
        #expect(tracker.isEmpty)
    }

    @Test func finishingReportsTheFinalNameOnce() {
        var tracker = confirmed()
        tracker.vanished(path: chrome.trackedPath, finalPath: "/d/Movie (1).mkv", at: start + 5)
        let items = tracker.drain()
        #expect(items.count == 1)
        #expect(items.first?.state == .finished)
        #expect(items.first?.displayName == "Movie (1).mkv")
        #expect(items.first?.throughput == nil)
        #expect(tracker.drain().isEmpty)
        #expect(tracker.isEmpty)
    }

    @Test func vanishingWithoutAFinalFileFails() {
        var tracker = confirmed()
        tracker.vanished(path: chrome.trackedPath, finalPath: nil, at: start + 5)
        #expect(tracker.drain().map(\.state) == [.failed])
    }

    @Test func telegramKeepsItsDisplayNameWhenFinished() throws {
        let telegram = try #require(PartialFileRules.classify(
            path: "/t/a/postbox/media/telegram-cloud-document-1_partial", rootKind: .telegramMedia
        ))
        var tracker = PartialDownloadTracker()
        tracker.observe(telegram, size: 0, at: start)
        tracker.observe(telegram, size: 5_000_000, at: start + 3)
        tracker.vanished(path: telegram.trackedPath, finalPath: telegram.finalPath, at: start + 4)
        let item = try #require(tracker.drain().first)
        #expect(item.displayName == "Telegram download")
        #expect(item.sourceApp == "Telegram")
        #expect(item.state == .finished)
    }

    @Test func stallsAfterTheTimeoutAndEndQuietly() {
        var tracker = confirmed()
        tracker.expireStalled(at: start + 3 + 59)
        #expect(tracker.drain().map(\.state) == [.active])
        tracker.expireStalled(at: start + 3 + 60)
        #expect(tracker.drain().map(\.state) == [.failed])
        #expect(tracker.isEmpty)
    }

    @Test func unconfirmedStallsVanishSilently() {
        var tracker = PartialDownloadTracker()
        tracker.observe(chrome, size: 10, at: start)
        tracker.expireStalled(at: start + 61)
        #expect(tracker.drain().isEmpty)
        #expect(tracker.isEmpty)
    }

    @Test func growthResetsTheStallClock() {
        var tracker = confirmed()
        tracker.observe(chrome, size: 9_000_000, at: start + 50)
        tracker.expireStalled(at: start + 100)
        #expect(tracker.drain().map(\.state) == [.active])
    }

    @Test func idsAreStablePerPath() {
        #expect(PartialDownloadTracker.stableID(for: "/a") == PartialDownloadTracker.stableID(for: "/a"))
        #expect(PartialDownloadTracker.stableID(for: "/a") != PartialDownloadTracker.stableID(for: "/b"))
    }

    private func confirmed() -> PartialDownloadTracker {
        var tracker = PartialDownloadTracker()
        tracker.observe(chrome, size: 0, at: start)
        tracker.observe(chrome, size: 2_000_000, at: start + 2)
        tracker.observe(chrome, size: 4_000_000, at: start + 3)
        _ = tracker.drain()
        return tracker
    }
}
