import Foundation
import LiovaPluginKit

/// What a hook invocation should do once its input is understood.
public enum AgentHookAction: Equatable, Sendable {
    /// Report the event to Liova and print nothing.
    case event(AgentEvent)
    /// Ask Liova for a decision and print it for the agent.
    case permission(AgentPermissionRequest)
    /// Nothing to send. The reason is only for `LIOVA_HOOK_DEBUG` logging.
    case ignore(reason: String)
}

/// Translates one agent's hook input into Liova's agent vocabulary, and Liova's answer back
/// into what the agent expects on stdout.
///
/// Adapters are pure (no I/O, no clock) so every mapping is unit-tested. They share the
/// privacy rules in ``AgentHookFields``: prompts, model output, file contents and tool output
/// never leave the hook.
public protocol AgentHookAdapter: Sendable {
    /// Adapts one hook input (the agent's JSON payload).
    func adapt(_ input: Data) -> AgentHookAction

    /// What to print for Liova's answer to a permission request, or `nil` to print nothing so
    /// the agent falls back to its own prompt.
    func output(for decision: AgentDecision) -> String?
}

/// Field clean-up shared by the agent adapters. Every string that reaches Liova goes through
/// here, so it is single-line where it should be, stripped of control and bidi characters, and
/// within the wire limits by characters **and** bytes.
enum AgentHookFields {
    /// Byte caps that keep a request far below the 64 KiB wire limit whatever the input.
    static let maxDetailBytes = 2048
    static let maxSummaryBytes = 16 * 1024
    /// Longest command shown in an event's detail.
    static let maxCommandPreviewLength = 80

    /// Parses the hook payload into an object, or explains why it can't.
    static func object(_ input: Data) -> Result<HookInput, IgnoreReason> {
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                return .failure(IgnoreReason("Hook input is not a JSON object."))
            }
            return .success(HookInput(parsed))
        } catch {
            return .failure(IgnoreReason("Hook input is not valid JSON."))
        }
    }

    struct IgnoreReason: Error {
        let text: String

        init(_ text: String) {
            self.text = text
        }
    }

    /// A session identifier, single-line and within limits, or `nil` if empty.
    static func sessionID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let sessionID = AgentText.truncate(
            AgentText.singleLine(raw),
            maxCharacters: LiovaValidation.maxSessionIDLength,
            maxBytes: 1024
        )
        return sessionID.isEmpty ? nil : sessionID
    }

    /// The project name for a working directory: its last path component, never the full path.
    static func project(fromPath path: String?) -> String? {
        guard let name = path.flatMap(AgentText.lastPathComponent) else { return nil }
        let project = AgentText.truncate(
            AgentText.singleLine(name),
            maxCharacters: LiovaValidation.maxProjectLength,
            maxBytes: 1024
        )
        return project.isEmpty ? nil : project
    }

    /// Event detail text: one line, within limits; `nil` when nothing is left.
    static func detail(_ text: String?) -> String? {
        guard let text else { return nil }
        let detail = AgentText.truncate(
            AgentText.singleLine(text),
            maxCharacters: LiovaValidation.maxDetailLength,
            maxBytes: maxDetailBytes
        )
        return detail.isEmpty ? nil : detail
    }

    /// A tool name for a permission request: one line, within limits; `nil` when empty.
    static func toolName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let tool = AgentText.singleLine(raw)
        guard !tool.isEmpty else { return nil }
        return AgentText.truncate(tool, maxCharacters: LiovaValidation.maxAgentNameLength, maxBytes: 512)
    }

    /// A permission summary, shown verbatim: line breaks kept, control characters removed.
    static func summary(_ text: String) -> String {
        AgentText.truncate(
            AgentText.removingControlCharacters(text).trimmingCharacters(in: .whitespacesAndNewlines),
            maxCharacters: LiovaValidation.maxSummaryLength,
            maxBytes: maxSummaryBytes
        )
    }

    /// `seconds` clamped to what Liova accepts for a permission request.
    static func permissionTimeout(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, LiovaValidation.agentTimeoutRange.lowerBound), LiovaValidation.agentTimeoutRange.upperBound)
    }

    /// "Running `swift test`" for a shell command (first non-blank line only), or a generic
    /// phrase when there's no command.
    static func runningDetail(_ command: String?) -> String {
        guard let command = command.flatMap(AgentText.firstNonBlankLine) else { return "Running a command" }
        let preview = AgentText.truncate(
            AgentText.singleLine(command),
            maxCharacters: maxCommandPreviewLength,
            maxBytes: 1024
        )
        return "Running `\(preview)`"
    }

    /// "Editing App.swift" for a path, or "Editing a file" when there's none.
    static func fileDetail(_ verb: String, path: String?, fallback: String) -> String {
        path.flatMap(AgentText.lastPathComponent).map { "\(verb) \($0)" } ?? fallback
    }

    /// One line of JSON with sorted keys, or `nil` if there's nothing to show.
    static func compactJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [
                  .sortedKeys,
                  .withoutEscapingSlashes,
              ])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A shell command given as a string, or as an argument list (`["bash", "-lc", "make"]`).
    static func command(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        guard let words = value as? [String], !words.isEmpty else { return nil }
        let shells: Set = ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"]
        if words.count == 3, shells.contains(words[0]), ["-c", "-lc"].contains(words[1]) {
            return words[2]
        }
        return words.map(ShellWords.quote).joined(separator: " ")
    }
}

/// Typed, forgiving access to a hook's JSON object: wrong types read as missing.
struct HookInput {
    let raw: [String: Any]

    init(_ raw: [String: Any]) {
        self.raw = raw
    }

    func string(_ key: String) -> String? {
        raw[key] as? String
    }

    func bool(_ key: String) -> Bool? {
        // JSONSerialization represents booleans as NSNumber; only accept real booleans.
        guard let number = raw[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    func object(_ key: String) -> HookInput? {
        (raw[key] as? [String: Any]).map(HookInput.init)
    }

    /// The first string of a string array, e.g. Cursor's `workspace_roots`.
    func firstString(_ key: String) -> String? {
        (raw[key] as? [Any])?.first as? String
    }
}
