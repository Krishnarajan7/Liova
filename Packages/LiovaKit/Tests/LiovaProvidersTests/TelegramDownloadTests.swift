import Foundation
@testable import LiovaProviders
import Testing

/// Builds the record Telegram keeps beside a download, byte for byte.
enum TelegramRecord {
    static func data(total: Int64, ranges: [(offset: Int64, length: Int64)], stale: Int = 0) -> Data {
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(0x7BAC_1487))
        append(UInt32(0x1056_BC39)) // checksum: not read
        append(UInt32(ranges.count))
        append(total)
        for range in ranges {
            append(range.offset)
            append(range.length)
        }
        // Telegram rewrites the record in place: an earlier, longer one leaves bytes behind.
        for _ in 0 ..< stale {
            append(Int64(0xDDD8_0000))
            append(Int64(0x20000))
        }
        return data
    }
}

struct TelegramPartialMetaTests {
    @Test func readsTheFullSizeAndWhatHasArrived() {
        let record = TelegramRecord.data(total: 2_606_346_257, ranges: [
            (0, 0x360000), (0x380000, 0x20000), (0x3C0000, 0x20000), (0x9B55_1000, 0x4A011),
        ])
        let progress = TelegramPartialMeta.parse(record)
        #expect(progress == TelegramPartialProgress(completed: 4_104_209, total: 2_606_346_257))
        #expect(progress?.isComplete == false)
    }

    @Test func aFinishedDownloadIsOneRangeAndStaleBytesAreIgnored() {
        let record = TelegramRecord.data(total: 3_723_339_087, ranges: [(0, 3_723_339_087)], stale: 4)
        #expect(record.count == 100)
        let progress = TelegramPartialMeta.parse(record)
        #expect(progress == TelegramPartialProgress(completed: 3_723_339_087, total: 3_723_339_087))
        #expect(progress?.isComplete == true)
    }

    @Test func aDownloadThatHasNotStartedHasNoSizeYet() {
        let progress = TelegramPartialMeta.parse(TelegramRecord.data(total: -1, ranges: []))
        #expect(progress == TelegramPartialProgress(completed: 0, total: nil))
        #expect(progress?.isComplete == false)
    }

    @Test func overlappingRangesCountOnce() {
        let record = TelegramRecord.data(total: 1000, ranges: [(100, 200), (0, 150), (250, 100), (900, 100)])
        #expect(TelegramPartialMeta.parse(record) == TelegramPartialProgress(completed: 450, total: 1000))
    }

    @Test func anythingElseIsNotARecord() {
        let good = TelegramRecord.data(total: 1000, ranges: [(0, 10)])
        #expect(TelegramPartialMeta.parse(Data()) == nil)
        #expect(TelegramPartialMeta.parse(good.prefix(19)) == nil)
        #expect(TelegramPartialMeta.parse(good.dropLast(1)) == nil) // says one range, holds less
        #expect(TelegramPartialMeta.parse(Data(repeating: 0, count: 36)) == nil) // wrong magic
        #expect(TelegramPartialMeta.parse(TelegramRecord.data(total: 1000, ranges: [(-5, 10)])) == nil)
        #expect(TelegramPartialMeta.parse(TelegramRecord.data(total: 1000, ranges: [(.max, 10)])) == nil)
        #expect(TelegramPartialMeta.parse(TelegramRecord.data(total: -7, ranges: [])) == nil)
        #expect(TelegramPartialMeta.parse(good + Data(count: TelegramPartialMeta.maximumSize)) == nil)
    }

    @Test func aSliceOfLargerDataParsesTheSame() {
        let good = TelegramRecord.data(total: 1000, ranges: [(0, 10)])
        let slice = (Data(repeating: 9, count: 7) + good).dropFirst(7)
        #expect(TelegramPartialMeta.parse(slice) == TelegramPartialProgress(completed: 10, total: 1000))
    }
}

struct TelegramTrackerTests {
    let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func aKnownTotalGivesProgressAndTimeLeft() throws {
        let telegram = try #require(PartialFileRules.classify(
            path: "/t/a/postbox/media/telegram-cloud-document-1_partial", rootKind: .telegramMedia
        ))
        #expect(telegram.progressRecordPath == telegram.trackedPath + ".meta")
        var tracker = PartialDownloadTracker()
        tracker.observe(telegram, size: 0, total: 100_000_000, at: start)
        tracker.observe(telegram, size: 10_000_000, total: 100_000_000, at: start + 2)
        tracker.observe(telegram, size: 20_000_000, total: 100_000_000, at: start + 4)
        let item = try #require(tracker.drain().first)
        #expect(item.totalBytes == 100_000_000)
        #expect(item.fractionCompleted == 0.2)
        #expect(item.throughput == 5_000_000)
        #expect(item.estimatedTimeRemaining == 16)

        tracker.vanished(path: telegram.trackedPath, finalPath: telegram.finalPath, at: start + 5)
        let finished = try #require(tracker.drain().first)
        #expect(finished.state == .finished)
        #expect(finished.bytesCompleted == 100_000_000)
    }
}

/// Telegram's way of downloading, against the real file system in a temporary directory.
@MainActor
@Suite(.serialized)
struct TelegramSourceIntegrationTests {
    let media: URL
    let total: Int64 = 4 * 1024 * 1024

    init() throws {
        media = FileManager.default.temporaryDirectory
            .appendingPathComponent("liova-telegram-\(UUID().uuidString)/account-1/postbox/media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }

    private func makeSource() -> PartialFileDownloadSource {
        let path = media.path
        return PartialFileDownloadSource(
            roots: { [.init(path: path, kind: .telegramMedia)] },
            configuration: .init(
                tracker: .init(minimumSize: 64 * 1024, minimumAge: 0.2, stallTimeout: 60),
                latency: 0.05,
                sampleInterval: 0.1,
                sampleLeeway: 0.02
            )
        )
    }

    private func started(_ source: PartialFileDownloadSource, _ recorder: DownloadRecorder) async throws {
        source.start { recorder.record($0) }
        for _ in 0 ..< 200 where !source.isMonitoring {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(source.isMonitoring)
    }

    /// Writes the record in place, as Telegram does, and touches the partial file.
    private func arrive(_ bytes: Int64, partial: URL) throws {
        let record = TelegramRecord.data(total: total, ranges: bytes > 0 ? [(Int64(0), bytes)] : [])
        let meta = URL(fileURLWithPath: partial.path + ".meta")
        if !FileManager.default.fileExists(atPath: meta.path) {
            FileManager.default.createFile(atPath: meta.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: meta)
        try handle.write(contentsOf: record)
        try handle.close()
        let file = try FileHandle(forWritingTo: partial)
        try file.seek(toOffset: UInt64(max(0, bytes - 1)))
        try file.write(contentsOf: Data([1]))
        try file.close()
    }

    @Test func progressComesFromTheRecordAndItFinishesWhenTheFinalFileAppears() async throws {
        defer { try? FileManager.default.removeItem(at: media.deletingLastPathComponent()) }
        let source = makeSource()
        let recorder = DownloadRecorder()
        try await started(source, recorder)
        defer { source.stop() }

        // Like a video: the file is full-length from the start, because the end arrives first.
        let partial = media.appendingPathComponent("telegram-cloud-document-5-42_partial")
        let final = media.appendingPathComponent("telegram-cloud-document-5-42")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let file = try FileHandle(forWritingTo: partial)
        try file.truncate(atOffset: UInt64(total))
        try file.close()

        var arrived: Int64 = 0
        var grew = false
        for _ in 0 ..< 120 where !grew && arrived < total - 256 * 1024 {
            arrived += 64 * 1024
            try arrive(arrived, partial: partial)
            try await Task.sleep(for: .milliseconds(40))
            grew = Set(recorder.allItems.filter(\.isActive).map(\.bytesCompleted)).count >= 2
        }
        #expect(grew)
        let active = try #require(recorder.allItems.last { $0.isActive })
        #expect(active.displayName == "Telegram download")
        #expect(active.totalBytes == total)
        #expect(active.bytesCompleted <= arrived)
        #expect(recorder.allItems.allSatisfy { $0.bytesCompleted < total })

        // Done: Telegram links the final name to the partial file, which stays.
        try arrive(total, partial: partial)
        try FileManager.default.linkItem(at: partial, to: final)
        let finished = await recorder.wait { deliveries in
            deliveries.contains { batch in batch.contains { $0.state == .finished } }
        }
        #expect(finished)
        let item = try #require(recorder.allItems.first { $0.state == .finished })
        #expect(item.id == active.id)
        #expect(item.bytesCompleted == total)
        #expect(FileManager.default.fileExists(atPath: partial.path))

        // Telegram touching a finished download later doesn't bring it back.
        let before = recorder.deliveries.count
        try arrive(total, partial: partial)
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.deliveries.dropFirst(before).allSatisfy { $0.allSatisfy { !$0.isActive } })
        #expect(recorder.allItems.filter { $0.state == .finished }.count == 1)
    }
}
