import Foundation
import LiovaPluginKit

/// Maps agent sessions and permission prompts to activities. Pure, so it's unit-tested.
///
/// Priorities: a permission prompt is `.high` (it blocks the agent until you answer), a
/// working session is `.normal`, an idle session is `.low` (below music). A finished turn
/// flashes briefly at `.high`, then leaves.
public enum AgentIslandPolicy {
    /// Reserved (`system.`) so plugins can't spoof or dismiss agent prompts.
    public static let source = "system.agents"
    static let sessionPrefix = "agent.session."
    static let promptPrefix = "agent.prompt."

    /// Sessions with no event for this long are considered gone (e.g. the terminal was closed).
    public static let staleAfter: TimeInterval = 15 * 60
    /// How long "finished" stays in the notch.
    public static let finishedDuration: TimeInterval = 6

    public static func displayName(forAgent agent: String) -> String {
        switch agent {
        case "claude-code": "Claude Code"
        case "codex": "Codex"
        case "cursor": "Cursor"
        case "gemini-cli": "Gemini CLI"
        default: agent
        }
    }

    public static func tint(forAgent agent: String) -> ActivityTint {
        switch agent {
        case "claude-code": .orange
        case "codex": .gray
        case "cursor": .blue
        case "gemini-cli": .purple
        default: .accent
        }
    }

    // MARK: - Identity

    public static func sessionActivityID(agent: String, sessionID: String) -> ActivityID {
        ActivityID(sessionPrefix + sanitize("\(agent).\(sessionID)"))
    }

    public static func promptActivityID(_ promptID: UUID) -> ActivityID {
        ActivityID(promptPrefix + promptID.uuidString.lowercased())
    }

    public static func isPrompt(_ id: ActivityID) -> Bool {
        id.rawValue.hasPrefix(promptPrefix)
    }

    public static func promptID(from id: ActivityID) -> UUID? {
        guard isPrompt(id) else { return nil }
        return UUID(uuidString: String(id.rawValue.dropFirst(promptPrefix.count)))
    }

    /// Keeps activity IDs inside the allowed character set and length.
    static func sanitize(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            LiovaValidation.isIdentifierCharacter(scalar) ? Character(scalar) : "-"
        }
        let maxLength = LiovaValidation.maxIDLength - max(sessionPrefix.count, promptPrefix.count)
        return String(String(allowed).prefix(maxLength))
    }

    // MARK: - Activities

    public static func sessionActivity(for session: AgentSession, now: Date) -> Activity? {
        let name = displayName(forAgent: session.agent)
        let title = session.project.map { "\(name) · \($0)" } ?? name
        let id = sessionActivityID(agent: session.agent, sessionID: session.sessionID)
        switch session.state {
        case .working:
            return Activity(
                id: id, source: source, priority: .normal, title: title,
                subtitle: session.detail ?? "Working…", symbol: "sparkle",
                tint: tint(forAgent: session.agent), expiresAt: now + staleAfter
            )
        case .waitingForUser:
            return Activity(
                id: id, source: source, priority: .low, title: title,
                subtitle: "Waiting for you", symbol: "ellipsis.bubble.fill",
                tint: tint(forAgent: session.agent), expiresAt: now + staleAfter
            )
        case .finished:
            return Activity(
                id: id, source: source, priority: .high, title: title,
                subtitle: "Finished", symbol: "checkmark.circle.fill",
                tint: .green, expiresAt: now + finishedDuration
            )
        }
    }

    public static func promptActivity(for prompt: AgentPermissionPrompt) -> Activity {
        let name = displayName(forAgent: prompt.agent)
        let firstLine = prompt.summary.split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init) ?? prompt.summary
        return Activity(
            id: promptActivityID(prompt.id),
            source: source,
            priority: .high,
            title: "\(name) wants to use \(prompt.tool)",
            subtitle: String(firstLine.prefix(LiovaValidation.maxSubtitleLength)),
            symbol: "hand.raised.fill",
            tint: .orange,
            expiresAt: prompt.deadline
        )
    }
}

/// One coding-agent session, as Liova sees it.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case working
        case waitingForUser
        case finished
    }

    public var id: String {
        "\(agent).\(sessionID)"
    }

    public var agent: String
    public var sessionID: String
    public var project: String?
    public var state: State
    public var detail: String?
    public var updatedAt: Date
}

/// A permission request waiting for the user's answer.
public struct AgentPermissionPrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var agent: String
    public var sessionID: String
    public var project: String?
    public var tool: String
    public var summary: String
    public var deadline: Date
}
