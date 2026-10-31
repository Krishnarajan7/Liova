import Foundation
import LiovaCore
import LiovaPluginKit
import Testing

private func activity(_ id: String, priority: ActivityPriority, title: String? = nil) -> Activity {
    Activity(id: ActivityID(id), source: "test", priority: priority, title: title ?? id)
}

/// Bringing an activity to the front from the open notch.
@MainActor
struct ActivityEngineFrontTests {
    let engine = ActivityEngine()

    init() throws {
        try engine.start(activity("music", priority: .low))
        try engine.start(activity("agent", priority: .normal))
    }

    @Test func broughtToFrontBeatsWhatOutranksIt() {
        #expect(engine.current?.id == "agent")
        engine.bringToFront("music")
        #expect(engine.activities.map(\.id) == ["music", "agent"])
    }

    @Test func urgentStillComesOverItAndItReturns() throws {
        engine.bringToFront("music")
        try engine.start(activity("prompt", priority: .high))
        #expect(engine.current?.id == "prompt")
        engine.end("prompt")
        #expect(engine.current?.id == "music")
    }

    @Test func itStaysInFrontThroughUpdatesAndNewArrivals() throws {
        engine.bringToFront("music")
        try engine.start(activity("agent", priority: .normal, title: "Running tests"))
        try engine.start(activity("timer", priority: .normal))
        #expect(engine.current?.id == "music")
    }

    @Test func endingItForgetsIt() throws {
        engine.bringToFront("music")
        engine.end("music")
        #expect(engine.frontID == nil)
        // Music coming back later ranks normally again.
        try engine.start(activity("music", priority: .low))
        #expect(engine.current?.id == "agent")
    }

    @Test func pickingAnotherMovesTheFront() {
        engine.bringToFront("music")
        engine.bringToFront("agent")
        #expect(engine.activities.map(\.id) == ["agent", "music"])
    }

    @Test func unknownIDsAreIgnored() {
        engine.bringToFront("nope")
        #expect(engine.frontID == nil)
        #expect(engine.current?.id == "agent")
    }
}
