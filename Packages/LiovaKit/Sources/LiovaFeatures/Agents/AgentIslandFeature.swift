import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaProviders
import Observation

/// Agent Island: coding agents (Claude Code, Codex, Cursor, Gemini CLI) in the notch.
///
/// Events arrive from agent hooks through the `liova` CLI and the plugin socket. Each
/// session becomes one activity that updates in place. A permission request becomes a
/// high-priority prompt with Allow / Deny buttons; the hook waits until the user answers,
/// the deadline passes (→ `.ask`, so the agent shows its own prompt), or the session moves
/// on without us (answered in the terminal).
@MainActor
@Observable
public final class AgentIslandFeature {
    public private(set) var sessions: [String: AgentSession] = [:]
    /// Waiting prompts, oldest first.
    public private(set) var prompts: [AgentPermissionPrompt] = []
    /// The app (and terminal device) each session runs in, by session key, once known.
    public private(set) var terminals: [String: AgentTerminal] = [:]

    /// Called when a prompt appears (to open the notch) and when the last one is answered.
    @ObservationIgnored public var onAttentionChange: ((Bool) -> Void)?

    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private let settings: LiovaSettings
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let focus: (any AgentTerminalFocusing)?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<AgentDecision, Never>] = [:]
    @ObservationIgnored private var deadlines: [UUID: Task<Void, Never>] = [:]
    /// The "agents over music" choice the live sessions were published with.
    @ObservationIgnored private var publishedOverMusic: Bool?

    public static let maxSessions = 32
    public static let maxPrompts = 8

    public init(
        engine: ActivityEngine,
        settings: LiovaSettings,
        focus: (any AgentTerminalFocusing)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.engine = engine
        self.settings = settings
        self.focus = focus
        self.now = now
    }

    public var isEnabled: Bool {
        settings.agentIslandEnabled
    }

    /// Clears everything when the feature is turned off; re-ranks live sessions when the
    /// user changes whether agents or music come first.
    public func syncWithSettings() {
        guard settings.agentIslandEnabled else {
            stop()
            return
        }
        guard let publishedOverMusic, publishedOverMusic != settings.agentsOverMusic else { return }
        // Only sessions still in the notch, at their own times, so nothing stale comes back.
        for session in sessions.values {
            let id = AgentIslandPolicy.sessionActivityID(agent: session.agent, sessionID: session.sessionID)
            if engine.activity(id) != nil {
                publish(session, at: session.updatedAt)
            }
        }
    }

    /// Answers every waiting prompt with `.ask` and clears all agent activities.
    public func stop() {
        for prompt in prompts {
            finish(prompt.id, with: .ask)
        }
        sessions.removeAll()
        terminals.removeAll()
        engine.endAll(source: AgentIslandPolicy.source)
    }

    // MARK: - Jump to the terminal

    /// Whether Liova knows where this session runs, so the card can offer to go there.
    public func canJump(toAgent agent: String, sessionID: String) -> Bool {
        focus != nil && terminals["\(agent).\(sessionID)"] != nil
    }

    /// Brings the session's terminal (its tab, where the app can be asked) to the front.
    public func jumpToTerminal(agent: String, sessionID: String) {
        let key = "\(agent).\(sessionID)"
        guard let focus, let terminal = terminals[key] else { return }
        Log.feature.info("Jumping to an agent's terminal")
        focus.focus(terminal, project: sessions[key]?.project ?? prompts.first { $0.sessionKey == key }?.project)
    }

    /// The session an activity in the notch stands for, if it's a session's.
    public func session(for activityID: ActivityID) -> AgentSession? {
        sessions.values.first {
            AgentIslandPolicy.sessionActivityID(agent: $0.agent, sessionID: $0.sessionID) == activityID
        }
    }

    /// Remembers where a session runs, the first time it reports and again when it restarts
    /// (a resumed session can be in another window). `origin` looks the app up from the
    /// reporting process, so it's only asked when the answer is needed.
    private func noteTerminal(for key: String, refresh: Bool, origin: (@MainActor () -> AgentTerminal?)?) {
        guard let origin, refresh || terminals[key] == nil,
              terminals[key] != nil || terminals.count < Self.maxSessions + Self.maxPrompts else { return }
        if let terminal = origin() {
            terminals[key] = terminal
            let app = terminal.bundleID ?? "an app"
            Log.feature.info("Agent session runs in \(app, privacy: .public), tab known: \(terminal.tty != nil)")
        }
    }

    // MARK: - Events

    public func handle(_ event: AgentEvent, origin: (@MainActor () -> AgentTerminal?)? = nil) {
        guard isEnabled else { return }
        let key = "\(event.agent).\(event.sessionID)"
        let date = now()

        if event.kind == .sessionEnded {
            answerElsewhere(sessionKey: key)
            sessions[key] = nil
            terminals[key] = nil
            engine.end(AgentIslandPolicy.sessionActivityID(agent: event.agent, sessionID: event.sessionID))
            return
        }
        guard sessions[key] != nil || sessions.count < Self.maxSessions else { return }
        noteTerminal(for: key, refresh: event.kind == .sessionStarted, origin: origin)

        var session = sessions[key] ?? AgentSession(
            agent: event.agent, sessionID: event.sessionID, project: event.project,
            state: .working, detail: nil, updatedAt: date
        )
        if let project = event.project {
            session.project = project
        }
        session.updatedAt = date

        guard event.kind != .sessionStarted else {
            // A session that hasn't done anything yet isn't worth a spot in the notch.
            sessions[key] = session
            return
        }
        apply(event, to: &session, key: key)
        sessions[key] = session
        publish(session, at: date)
    }

    private func apply(_ event: AgentEvent, to session: inout AgentSession, key: String) {
        switch event.kind {
        case .working:
            answerElsewhere(sessionKey: key)
            session.state = .working
            session.detail = nil
        case .toolStarted:
            session.state = .working
            session.detail = event.detail ?? session.detail
        case .toolFinished:
            session.state = .working
        case .waitingForUser:
            answerElsewhere(sessionKey: key)
            session.state = .waitingForUser
        case .finished:
            answerElsewhere(sessionKey: key)
            session.state = .finished
            session.detail = nil
        case .sessionStarted, .sessionEnded:
            break // handled by the caller
        }
    }

    // MARK: - Permission prompts

    /// Shows a prompt and waits for the user's answer (or the deadline).
    public func requestPermission(
        _ request: AgentPermissionRequest,
        origin: (@MainActor () -> AgentTerminal?)? = nil
    ) async -> AgentDecision {
        guard isEnabled, prompts.count < Self.maxPrompts else { return .ask }
        noteTerminal(for: "\(request.agent).\(request.sessionID)", refresh: false, origin: origin)
        let prompt = AgentPermissionPrompt(
            id: UUID(), agent: request.agent, sessionID: request.sessionID, project: request.project,
            tool: request.tool, summary: request.summary, deadline: now() + request.timeout
        )
        do {
            try engine.start(AgentIslandPolicy.promptActivity(for: prompt))
        } catch {
            Log.feature.error("Agent prompt rejected: \(String(describing: error), privacy: .public)")
            return .ask
        }
        prompts.append(prompt)
        if prompts.count == 1, settings.agentOpensNotchForApprovals {
            onAttentionChange?(true)
        }
        Log.feature.info("Agent permission requested: \(request.tool, privacy: .public)")

        let timeout = request.timeout
        deadlines[prompt.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.finish(prompt.id, with: .ask)
        }
        return await withCheckedContinuation { continuation in
            waiters[prompt.id] = continuation
        }
    }

    /// The user's answer from the notch.
    public func answer(_ promptID: UUID, with decision: AgentDecision) {
        Log.feature.info("Agent permission answered: \(decision.rawValue, privacy: .public)")
        finish(promptID, with: decision)
    }

    public func prompt(_ id: UUID) -> AgentPermissionPrompt? {
        prompts.first { $0.id == id }
    }

    // MARK: - Internals

    private func publish(_ session: AgentSession, at date: Date) {
        publishedOverMusic = settings.agentsOverMusic
        let activity = AgentIslandPolicy.sessionActivity(for: session, now: date, overMusic: settings.agentsOverMusic)
        guard let activity else { return }
        do {
            try engine.start(activity)
        } catch {
            Log.feature.error("Agent activity rejected: \(String(describing: error), privacy: .public)")
        }
    }

    /// The session moved on without us, so its prompts were answered in the terminal.
    private func answerElsewhere(sessionKey: String) {
        for prompt in prompts where sessionKey == prompt.sessionKey {
            finish(prompt.id, with: .ask)
        }
    }

    private func finish(_ promptID: UUID, with decision: AgentDecision) {
        deadlines.removeValue(forKey: promptID)?.cancel()
        let hadPrompt = prompts.contains { $0.id == promptID }
        prompts.removeAll { $0.id == promptID }
        engine.end(AgentIslandPolicy.promptActivityID(promptID))
        waiters.removeValue(forKey: promptID)?.resume(returning: decision)
        if hadPrompt, prompts.isEmpty {
            onAttentionChange?(false)
        }
    }
}
