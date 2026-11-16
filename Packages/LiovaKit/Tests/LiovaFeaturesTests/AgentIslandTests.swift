import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
import Testing

/// Records where it was asked to go instead of moving windows.
@MainActor
private final class FakeFocus: AgentTerminalFocusing {
    var focused: [(terminal: AgentTerminal, project: String?)] = []

    func focus(_ terminal: AgentTerminal, project: String?) {
        focused.append((terminal, project))
    }
}

private let terminal = AgentTerminal(pid: 100, bundleID: "com.apple.Terminal", tty: "/dev/ttys002")

private func event(_ kind: AgentEventKind, session: String = "s1", detail: String? = nil) -> AgentEvent {
    AgentEvent(agent: "claude-code", sessionID: session, project: "Liova", kind: kind, detail: detail)
}

private func permission(session: String = "s1", timeout: TimeInterval = 30) -> AgentPermissionRequest {
    AgentPermissionRequest(
        agent: "claude-code", sessionID: session, project: "Liova", tool: "Bash",
        summary: "rm -rf node_modules\nnpm install", timeout: timeout
    )
}

@MainActor
struct AgentIslandTests {
    let engine = ActivityEngine()
    let settings: LiovaSettings
    let feature: AgentIslandFeature
    private let focus = FakeFocus()

    private let scratch = ScratchDefaults()

    init() throws {
        settings = LiovaSettings(defaults: scratch.defaults)
        feature = AgentIslandFeature(engine: engine, settings: settings, focus: focus)
    }

    @Test func usageIsRememberedWithoutTouchingTheNotch() {
        let usage = AgentUsage(fiveHour: .init(usedPercentage: 23), contextUsedPercentage: 40)
        feature.handle(AgentEvent(agent: "claude-code", sessionID: "s1", kind: .usage, usage: usage))
        #expect(feature.usage["claude-code"] == usage)
        // Numbers alone never put a session in the notch.
        #expect(feature.sessions.isEmpty)
        #expect(engine.current == nil)
        feature.stop()
        #expect(feature.usage.isEmpty)
    }

    @Test func usageReadsAsShortPartsAndWarnsNearTheLimit() throws {
        let now = Date(timeIntervalSince1970: 1_794_724_200)
        let usage = AgentUsage(
            fiveHour: .init(usedPercentage: 84.6, resetsAt: now.timeIntervalSince1970 + 3600),
            sevenDay: .init(usedPercentage: 41.2, resetsAt: nil),
            contextUsedPercentage: 12,
            costUSD: 1.234
        )
        let parts = try AgentUsagePolicy.parts(
            for: usage, now: now, timeZone: #require(TimeZone(identifier: "Asia/Kolkata")),
            locale: Locale(identifier: "en_US")
        )
        #expect(parts.map { $0.text.replacingOccurrences(of: "\u{202F}", with: " ") }
            == ["5h 85%, resets 1:00 PM", "7d 41%", "Context 12%", "$1.23"])
        #expect(parts.map(\.isWarning) == [true, false, false, false])
        // A reset time already past, and a cost under a cent, aren't shown.
        let stale = AgentUsage(fiveHour: .init(usedPercentage: 5, resetsAt: 10), costUSD: 0.001)
        #expect(AgentUsagePolicy.parts(for: stale, now: now).map(\.text) == ["5h 5%"])
    }

    @Test func jumpsToWhereTheSessionRuns() {
        feature.handle(event(.working)) { terminal }
        #expect(feature.canJump(toAgent: "claude-code", sessionID: "s1"))
        feature.jumpToTerminal(agent: "claude-code", sessionID: "s1")
        #expect(focus.focused.count == 1)
        #expect(focus.focused.first?.terminal == terminal)
        #expect(focus.focused.first?.project == "Liova")
    }

    @Test func looksTheTerminalUpOnceUntilTheSessionRestarts() {
        var lookups = 0
        let origin: @MainActor () -> AgentTerminal? = {
            lookups += 1
            return terminal
        }
        feature.handle(event(.working), origin: origin)
        feature.handle(event(.toolStarted, detail: "Running npm test"), origin: origin)
        feature.handle(event(.toolFinished), origin: origin)
        #expect(lookups == 1)
        feature.handle(event(.sessionStarted), origin: origin) // resumed, maybe in another window
        #expect(lookups == 2)
    }

    @Test func noKnownTerminalMeansNoJump() {
        feature.handle(event(.working)) { nil }
        #expect(!feature.canJump(toAgent: "claude-code", sessionID: "s1"))
        feature.jumpToTerminal(agent: "claude-code", sessionID: "s1")
        #expect(focus.focused.isEmpty)
    }

    @Test func anEndedSessionForgetsItsTerminal() {
        feature.handle(event(.working)) { terminal }
        feature.handle(event(.sessionEnded))
        #expect(feature.terminals.isEmpty)
        #expect(!feature.canJump(toAgent: "claude-code", sessionID: "s1"))
    }

    @Test func aPromptKnowsItsTerminalEvenBeforeAnyOtherEvent() async throws {
        let feature = feature
        let task = Task { await feature.requestPermission(permission()) { terminal } }
        let prompt = try await waitForPrompt()
        feature.jumpToTerminal(agent: prompt.agent, sessionID: prompt.sessionID)
        #expect(focus.focused.first?.project == "Liova")
        feature.answer(prompt.id, with: .ask)
        #expect(await task.value == .ask)
    }

    /// Waits until a prompt is showing (the request runs in its own task).
    private func waitForPrompt() async throws -> AgentPermissionPrompt {
        for _ in 0 ..< 200 {
            if let prompt = feature.prompts.first {
                return prompt
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }

    @Test func sessionStartAloneShowsNothing() {
        feature.handle(event(.sessionStarted))
        #expect(engine.current == nil)
        #expect(feature.sessions.count == 1)
    }

    @Test func workingSessionShowsAndUpdatesInPlace() {
        feature.handle(event(.working))
        feature.handle(event(.toolStarted, detail: "Running npm test"))
        #expect(engine.activities.count == 1)
        #expect(engine.current?.title == "Claude Code · Liova")
        #expect(engine.current?.subtitle == "Running npm test")
        #expect(engine.current?.priority == .normal)
    }

    @Test func musicFirstPutsAWorkingAgentBehindTheSong() throws {
        settings.agentsOverMusic = false
        try engine.start(Activity(id: "media", source: "media", priority: .low, title: "Dope Track"))
        feature.handle(event(.working))
        #expect(engine.current?.id == "media")
        #expect(engine.activities.count == 2)
    }

    @Test func musicFirstStillLetsFinishedThrough() throws {
        settings.agentsOverMusic = false
        try engine.start(Activity(id: "media", source: "media", priority: .low, title: "Dope Track"))
        feature.handle(event(.working))
        feature.handle(event(.finished))
        #expect(engine.current?.source == AgentIslandPolicy.source)
    }

    @Test func changingTheChoiceReranksLiveSessions() throws {
        try engine.start(Activity(id: "media", source: "media", priority: .low, title: "Dope Track"))
        feature.handle(event(.working))
        #expect(engine.current?.source == AgentIslandPolicy.source)
        settings.agentsOverMusic = false
        feature.syncWithSettings()
        #expect(engine.current?.id == "media")
        settings.agentsOverMusic = true
        feature.syncWithSettings()
        #expect(engine.current?.source == AgentIslandPolicy.source)
    }

    @Test func finishedFlashesThenExpires() throws {
        feature.handle(event(.working))
        feature.handle(event(.finished))
        let activity = try #require(engine.current)
        #expect(activity.subtitle == "Finished")
        #expect(activity.priority == .high)
        #expect(activity.expiresAt != nil)
    }

    @Test func sessionEndRemovesEverything() {
        feature.handle(event(.working))
        feature.handle(event(.sessionEnded))
        #expect(engine.current == nil)
        #expect(feature.sessions.isEmpty)
    }

    @Test func separateSessionsAreSeparateActivities() {
        feature.handle(event(.working, session: "a"))
        feature.handle(event(.working, session: "b"))
        #expect(engine.activities.count == 2)
    }

    @Test func allowFromTheNotchReachesTheHook() async throws {
        feature.handle(event(.working))
        let request = Task { await feature.requestPermission(permission()) }
        let prompt = try await waitForPrompt()
        #expect(engine.current?.id == AgentIslandPolicy.promptActivityID(prompt.id))
        #expect(engine.current?.priority == .high)
        feature.answer(prompt.id, with: .allow)
        #expect(await request.value == .allow)
        #expect(feature.prompts.isEmpty)
        #expect(engine.current?.id != AgentIslandPolicy.promptActivityID(prompt.id))
    }

    @Test func denyFromTheNotchReachesTheHook() async throws {
        let request = Task { await feature.requestPermission(permission()) }
        let prompt = try await waitForPrompt()
        feature.answer(prompt.id, with: .deny)
        #expect(await request.value == .deny)
    }

    @Test func deadlineDefersToTheAgent() async {
        let decision = await feature.requestPermission(permission(timeout: 1))
        #expect(decision == .ask)
        #expect(feature.prompts.isEmpty)
    }

    @Test func answeringInTheTerminalClearsThePrompt() async throws {
        let request = Task { await feature.requestPermission(permission()) }
        _ = try await waitForPrompt()
        // The user answered in the terminal; Claude finished the turn.
        feature.handle(event(.finished))
        #expect(await request.value == .ask)
        #expect(feature.prompts.isEmpty)
    }

    @Test func otherSessionsDontClearThePrompt() async throws {
        let request = Task { await feature.requestPermission(permission(session: "s1")) }
        let prompt = try await waitForPrompt()
        feature.handle(event(.finished, session: "other"))
        #expect(feature.prompts.count == 1)
        feature.answer(prompt.id, with: .allow)
        #expect(await request.value == .allow)
    }

    @Test func attentionOpensForFirstPromptAndClosesAfterLast() async throws {
        var changes: [Bool] = []
        feature.onAttentionChange = { changes.append($0) }
        let request = Task { await feature.requestPermission(permission()) }
        let prompt = try await waitForPrompt()
        feature.answer(prompt.id, with: .allow)
        _ = await request.value
        #expect(changes == [true, false])
    }

    @Test func noAutoOpenWhenTheUserTurnedItOff() async throws {
        settings.agentOpensNotchForApprovals = false
        var changes: [Bool] = []
        feature.onAttentionChange = { changes.append($0) }
        let request = Task { await feature.requestPermission(permission()) }
        let prompt = try await waitForPrompt()
        feature.answer(prompt.id, with: .allow)
        _ = await request.value
        #expect(changes == [false])
    }

    @Test func disabledFeatureDefersImmediately() async {
        settings.agentIslandEnabled = false
        feature.handle(event(.working))
        #expect(engine.current == nil)
        #expect(await feature.requestPermission(permission()) == .ask)
    }

    @Test func turningOffAnswersWaitingPrompts() async throws {
        feature.handle(event(.working))
        let request = Task { await feature.requestPermission(permission()) }
        _ = try await waitForPrompt()
        settings.agentIslandEnabled = false
        feature.syncWithSettings()
        #expect(await request.value == .ask)
        #expect(engine.current == nil)
    }

    @Test func tooManyPromptsDeferTheRest() async throws {
        var requests: [Task<AgentDecision, Never>] = []
        for index in 0 ..< AgentIslandFeature.maxPrompts {
            requests.append(Task { await feature.requestPermission(permission(session: "s\(index)")) })
        }
        for _ in 0 ..< 200 where feature.prompts.count < AgentIslandFeature.maxPrompts {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await feature.requestPermission(permission(session: "extra")) == .ask)
        feature.stop()
        for request in requests {
            #expect(await request.value == .ask)
        }
    }
}

struct AgentIslandPolicyTests {
    @Test func sessionIDsAreSanitizedIntoValidActivityIDs() {
        let id = AgentIslandPolicy.sessionActivityID(
            agent: "claude-code",
            sessionID: "a b/c:d" + String(repeating: "x", count: 300)
        )
        #expect(id.rawValue.count <= LiovaValidation.maxIDLength)
        #expect(id.rawValue.unicodeScalars.allSatisfy(LiovaValidation.isIdentifierCharacter))
    }

    @Test func promptIDsRoundTrip() {
        let uuid = UUID()
        let id = AgentIslandPolicy.promptActivityID(uuid)
        #expect(AgentIslandPolicy.isPrompt(id))
        #expect(AgentIslandPolicy.promptID(from: id) == uuid)
        #expect(AgentIslandPolicy.promptID(from: "agent.session.x") == nil)
    }

    @Test func promptShowsFirstLineOfSummary() {
        let prompt = AgentPermissionPrompt(
            id: UUID(), agent: "claude-code", sessionID: "s", project: nil, tool: "Bash",
            summary: "line one\nline two", deadline: Date()
        )
        let activity = AgentIslandPolicy.promptActivity(for: prompt)
        #expect(activity.subtitle == "line one")
        #expect(activity.source == AgentIslandPolicy.source)
        #expect(LiovaValidation.isReservedSource(activity.source))
    }

    @Test func knownAgentsHaveFriendlyNames() {
        #expect(AgentIslandPolicy.displayName(forAgent: "claude-code") == "Claude Code")
        #expect(AgentIslandPolicy.displayName(forAgent: "gemini-cli") == "Gemini CLI")
        #expect(AgentIslandPolicy.displayName(forAgent: "new-agent") == "new-agent")
    }
}
