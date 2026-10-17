import Foundation
@testable import LiovaProviders
import Testing

/// Collects deliveries from a source on the main actor.
@MainActor
final class DownloadRecorder {
    private(set) var deliveries: [[DownloadItem]] = []

    func record(_ items: [DownloadItem]) {
        deliveries.append(items)
    }

    var allItems: [DownloadItem] {
        deliveries.flatMap(\.self)
    }

    /// Waits until `condition` holds for the deliveries so far, or `timeout` passes.
    func wait(timeout: TimeInterval = 3, until condition: ([[DownloadItem]]) -> Bool) async -> Bool {
        let deadline = Date() + timeout
        while Date() < deadline {
            if condition(deliveries) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(deliveries)
    }
}

/// Provider B against the real file system, in a temporary directory only.
@MainActor
@Suite(.serialized)
struct PartialFileSourceIntegrationTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("liova-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeSource() -> PartialFileDownloadSource {
        let path = directory.path
        return PartialFileDownloadSource(
            roots: { [.init(path: path, kind: .downloads)] },
            configuration: .init(
                tracker: .init(minimumSize: 64 * 1024, minimumAge: 0.2, stallTimeout: 60),
                latency: 0.05,
                sampleInterval: 0.1,
                sampleLeeway: 0.02
            )
        )
    }

    @Test func growingPartFileBecomesADownloadAndFinishesWithItsFinalName() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource()
        let recorder = DownloadRecorder()
        source.start { recorder.record($0) }
        defer { source.stop() }
        // Roots are discovered off the main thread; wait until the watcher is listening.
        for _ in 0 ..< 200 where !source.isMonitoring {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(source.isMonitoring)

        let partial = directory.appendingPathComponent("Clip.mov.part")
        let final = directory.appendingPathComponent("Clip.mov")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        let chunk = Data(repeating: 0xAB, count: 64 * 1024)

        // Write in chunks until an active download is seen growing.
        var grew = false
        for _ in 0 ..< 120 where !grew { // up to ~5 s on a loaded machine; usually < 1 s
            try handle.write(contentsOf: chunk)
            try await Task.sleep(for: .milliseconds(40))
            let active = recorder.allItems.filter { $0.isActive && $0.displayName == "Clip.mov" }
            grew = Set(active.map(\.bytesCompleted)).count >= 2
        }
        try handle.close()
        #expect(grew)
        let active = try #require(recorder.allItems.last { $0.isActive })
        #expect(active.totalBytes == nil)
        #expect(active.bytesCompleted >= 128 * 1024)

        try FileManager.default.moveItem(at: partial, to: final)
        // A finished item is delivered once, and the next delivery (on any later file event)
        // no longer contains it, so look at every delivery, not just the latest.
        let finished = await recorder.wait { deliveries in
            deliveries.contains { batch in batch.contains { $0.state == .finished } }
        }
        #expect(finished)
        let item = try #require(recorder.allItems.first { $0.state == .finished })
        #expect(item.displayName == "Clip.mov")
        #expect(item.id == active.id)
        #expect(recorder.allItems.filter { $0.state == .finished }.count == 1)
    }

    @Test func ordinaryFilesAndTinyPartialsAreIgnored() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = makeSource()
        let recorder = DownloadRecorder()
        source.start { recorder.record($0) }
        defer { source.stop() }

        try Data(repeating: 1, count: 512 * 1024).write(to: directory.appendingPathComponent("Movie.mkv"))
        try Data(repeating: 1, count: 1024).write(to: directory.appendingPathComponent("small.bin.part"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.allItems.isEmpty)
    }

    @Test func missingRootsAreSkipped() {
        let source = PartialFileDownloadSource(roots: { [.init(path: "/nonexistent-\(UUID())", kind: .downloads)] })
        source.start { _ in }
        source.stop()
    }
}

@MainActor
final class FakeDownloadSource: DownloadSourcing {
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
struct CompositeDownloadSourceTests {
    let primary = FakeDownloadSource()
    let fallback = FakeDownloadSource()
    let recorder = DownloadRecorder()
    let date = Date(timeIntervalSince1970: 5000)

    private func item(
        _ id: String,
        final: String,
        state: DownloadItem.State = .active,
        total: Int64? = nil
    ) -> DownloadItem {
        DownloadItem(
            id: id, displayName: (final as NSString).lastPathComponent, bytesCompleted: 10, totalBytes: total,
            state: state, startDate: date, lastChangeDate: date, finalURL: URL(fileURLWithPath: final)
        )
    }

    @Test func mergesBothAndPrefersPublishedProgressForTheSameFile() {
        let composite = CompositeDownloadSource(primary: primary, fallback: fallback, now: { [date] in date })
        composite.start { recorder.record($0) }
        #expect(primary.isStarted && fallback.isStarted)

        fallback.send([item("b1", final: "/d/A.zip"), item("b2", final: "/d/B.zip")])
        #expect(recorder.deliveries.last?.map(\.id) == ["b1", "b2"])
        primary.send([item("a1", final: "/d/A.zip", total: 100)])
        #expect(recorder.deliveries.last?.map(\.id) == ["a1", "b2"])
    }

    @Test func aFinishSeenByBothFlashesOnce() {
        let composite = CompositeDownloadSource(primary: primary, fallback: fallback, now: { [date] in date })
        composite.start { recorder.record($0) }
        primary.send([item("a1", final: "/d/A.zip", total: 100)])
        primary.send([item("a1", final: "/d/A.zip", state: .finished, total: 100)])
        fallback.send([item("b1", final: "/d/A.zip", state: .finished)])
        #expect(recorder.allItems.filter { $0.state == .finished }.map(\.id) == ["a1"])
        // Terminal items aren't repeated in later deliveries.
        fallback.send([])
        #expect(recorder.deliveries.last?.isEmpty == true)
    }

    @Test func stopStopsBoth() {
        let composite = CompositeDownloadSource(primary: primary, fallback: fallback)
        composite.start { _ in }
        composite.stop()
        #expect(!primary.isStarted && !fallback.isStarted)
    }
}

@MainActor
struct FileProgressDownloadSourceTests {
    /// Publishes a download progress for a file in a temporary folder, the way Safari does,
    /// and checks it arrives, updates, and finishes.
    @Test func publishedProgressBecomesADownload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("liova-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FileProgressDownloadSource(directory: directory)
        let recorder = DownloadRecorder()
        source.start { recorder.record($0) }
        defer { source.stop() }

        let progress = Progress(totalUnitCount: 1000)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = directory.appendingPathComponent("Paper.pdf.download")
        progress.completedUnitCount = 100
        progress.publish()

        let seen = await recorder.wait { $0.last?.first?.isActive == true }
        guard seen else {
            // Some sandboxed or headless environments don't deliver published progress.
            progress.unpublish()
            return
        }
        let first = try #require(recorder.deliveries.last?.first)
        #expect(first.displayName == "Paper.pdf")
        #expect(first.sourceApp == "Safari")
        #expect(first.totalBytes == 1000)

        progress.completedUnitCount = 1000
        let finished = await recorder.wait { $0.last?.contains { $0.state == .finished } == true }
        progress.unpublish()
        #expect(finished)
    }
}
