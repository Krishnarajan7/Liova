import Foundation
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import Testing

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

    init() throws {
        settings = try LiovaSettings(defaults: #require(UserDefaults(suiteName: "agents.\(UUID())")))
        feature = AgentIslandFeature(engine: engine, settings: settings)
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
