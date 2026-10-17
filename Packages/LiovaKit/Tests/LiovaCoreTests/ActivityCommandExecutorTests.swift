import Foundation
import LiovaCore
import LiovaPluginKit
import Testing

@MainActor
struct ActivityCommandExecutorTests {
    let engine = ActivityEngine()
    var executor: ActivityCommandExecutor {
        ActivityCommandExecutor(engine: engine)
    }

    private func activity(_ id: String, source: String = "cli", title: String = "Hi") -> Activity {
        Activity(id: ActivityID(id), source: source, title: title)
    }

    @Test func startShowsActivity() {
        let response = executor.execute(.start(activity("build")), origin: .socket)
        #expect(response.ok)
        #expect(engine.current?.id == "build")
    }

    @Test func pingSucceeds() {
        #expect(executor.execute(.ping, origin: .socket).ok)
    }

    @Test func updateAppliesPatchAndKeepsIdentity() throws {
        try engine.start(activity("build"))
        let patch = ActivityPatch(id: "build", title: "Testing", progress: 0.5)
        #expect(executor.execute(.update(patch), origin: .socket).ok)
        #expect(engine.current?.title == "Testing")
        #expect(engine.current?.progress == 0.5)
        #expect(engine.current?.source == "cli")
    }

    @Test func updateUnknownIsNotFound() {
        let response = executor.execute(.update(ActivityPatch(id: "ghost", title: "x")), origin: .socket)
        #expect(response.error?.code == .notFound)
    }

    @Test func endAndEndAll() throws {
        try engine.start(activity("a"))
        try engine.start(activity("b"))
        #expect(executor.execute(.end("a"), origin: .socket).ok)
        #expect(engine.activities.map(\.id) == ["b"])
        #expect(executor.execute(.endAll(source: "cli"), origin: .socket).ok)
        #expect(engine.current == nil)
    }

    @Test func endUnknownIsNotFound() {
        #expect(executor.execute(.end("ghost"), origin: .socket).error?.code == .notFound)
    }

    @Test func listReturnsStackInOrder() throws {
        try engine.start(activity("a"))
        try engine.start(activity("b"))
        let response = executor.execute(.list, origin: .socket)
        #expect(response.activities?.map(\.id) == ["b", "a"])
    }

    @Test func systemActivitiesAreProtected() throws {
        try engine.start(activity("system.battery.low", source: "system.battery"))
        #expect(executor.execute(.end("system.battery.low"), origin: .socket).error?.code == .forbidden)
        #expect(executor.execute(
            .update(ActivityPatch(id: "system.battery.low", title: "Fake")), origin: .socket
        ).error?.code == .forbidden)
        #expect(executor.execute(.endAll(source: "system.battery"), origin: .socket).error?.code == .forbidden)
        #expect(executor.execute(
            .start(activity("spoof", source: "system.battery")), origin: .socket
        ).error?.code == .forbidden)
        #expect(engine.activities.count == 1)
    }

    @Test func cannotHijackAnotherSourcesID() throws {
        try engine.start(activity("build", source: "ci"))
        let response = executor.execute(.start(activity("build", source: "cli", title: "Pwned")), origin: .socket)
        #expect(response.error?.code == .forbidden)
        #expect(engine.current?.title == "Hi")
    }

    @Test func urlsCanOnlyTouchURLActivities() throws {
        try engine.start(activity("build", source: "cli"))
        try engine.start(activity("link", source: "url"))
        let origin = ActivityCommandExecutor.Origin.url(source: "url")
        #expect(executor.execute(.end("build"), origin: origin).error?.code == .forbidden)
        #expect(executor.execute(.endAll(source: "cli"), origin: origin).error?.code == .forbidden)
        #expect(executor.execute(.end("link"), origin: origin).ok)
        #expect(engine.activities.map(\.id) == ["build"])
    }

    @Test func engineLimitsMapToErrorCodes() {
        let tiny = ActivityEngine(limits: .init(maxActivitiesPerSource: 1, maxActivities: 2))
        let executor = ActivityCommandExecutor(engine: tiny)
        #expect(executor.execute(.start(activity("1")), origin: .socket).ok)
        #expect(executor.execute(.start(activity("2")), origin: .socket).error?.code == .rateLimited)
        #expect(executor.execute(.start(activity("3", source: "x")), origin: .socket).ok)
        #expect(executor.execute(.start(activity("4", source: "y")), origin: .socket).error?.code == .busy)
    }

    @Test func expiredStartIsBadRequest() {
        var expired = activity("old")
        expired.expiresAt = Date() - 10
        #expect(executor.execute(.start(expired), origin: .socket).error?.code == .badRequest)
    }
}
