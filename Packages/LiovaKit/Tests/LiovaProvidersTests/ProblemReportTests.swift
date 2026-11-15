import Foundation
@testable import LiovaProviders
import Testing

struct ProblemReportTests {
    private let root: URL
    private let system: URL
    private let own: URL
    private let store: ProblemReportStore
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "liova-reports-\(UUID().uuidString)")
        system = root.appending(path: "DiagnosticReports")
        own = root.appending(path: "Liova")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        store = ProblemReportStore(systemDirectory: system, ownDirectory: own)
    }

    private func addSystemReport(_ name: String, age: TimeInterval) throws {
        let url = system.appending(path: name)
        try Data("report".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now - age], ofItemAtPath: url.path)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func recognisesReportsAboutLiovaOnly() {
        #expect(ProblemReportStore.isLiovaReport("Liova-2026-11-15-101502.ips"))
        #expect(ProblemReportStore.isLiovaReport("Liova_2026-11-15-101502_Mac.hang"))
        #expect(ProblemReportStore.isLiovaReport("liova-2026-11-15-101502.ips")) // the command-line tool
        #expect(ProblemReportStore.isLiovaReport("Liova-crash-2026-11-15T101502Z.json"))
        #expect(!ProblemReportStore.isLiovaReport("Safari-2026-11-15-101502.ips"))
        #expect(!ProblemReportStore.isLiovaReport("LiovaNotes-2026-11-15-101502.ips"))
        #expect(!ProblemReportStore.isLiovaReport("Liova-notes.txt"))
    }

    @Test func listsRecentReportsNewestFirst() throws {
        defer { cleanUp() }
        try addSystemReport("Liova-older.ips", age: 5 * 86400)
        try addSystemReport("Liova-newer.ips", age: 3600)
        try addSystemReport("Liova-ancient.ips", age: 45 * 86400)
        try addSystemReport("Safari-today.ips", age: 60)
        try store.save(Data("{}".utf8), kind: "hang", at: now - 86400)
        let hang = try #require(try FileManager.default.contentsOfDirectory(atPath: own.path).first)

        let names = store.recent(now: now).map(\.url.lastPathComponent)
        #expect(names == ["Liova-newer.ips", hang, "Liova-older.ips"])
    }

    @Test func missingFoldersMeanNoReports() {
        defer { cleanUp() }
        let empty = ProblemReportStore(
            systemDirectory: root.appending(path: "nowhere"), ownDirectory: root.appending(path: "nothing")
        )
        #expect(empty.recent(now: now).isEmpty)
    }

    @Test func savedReportsNeverOverwriteEachOther() throws {
        defer { cleanUp() }
        let first = try store.save(Data("one".utf8), kind: "crash", at: now)
        let second = try store.save(Data("two".utf8), kind: "crash", at: now)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    @Test func onlyTheNewestSavedReportsAreKept() throws {
        defer { cleanUp() }
        for index in 0 ..< ProblemReportStore.maxSavedReports + 5 {
            try store.save(Data("x".utf8), kind: "diagnostic", at: now + Double(index) * 60)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: own.path)
        #expect(kept.count == ProblemReportStore.maxSavedReports)
        // The first five, the oldest, are the ones that went.
        let stamp = now.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted))
        #expect(!kept.contains("Liova-diagnostic-\(stamp).json"))
    }

    @Test func reportsAreNamedAfterTheWorstThingInThem() {
        #expect(ProblemReportRecorder.kind(crashes: 1, hangs: 2) == "crash")
        #expect(ProblemReportRecorder.kind(crashes: 0, hangs: 1) == "hang")
        #expect(ProblemReportRecorder.kind(crashes: 0, hangs: 0) == "diagnostic")
    }
}
