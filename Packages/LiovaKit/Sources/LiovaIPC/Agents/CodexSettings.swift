import Foundation

/// Liova's hooks for Codex CLI, in `~/.codex/hooks.json`.
///
/// Codex reads hooks from `hooks.json` or from inline `[hooks]` tables in `config.toml`. Liova
/// uses `hooks.json`, which has the same shape as Claude Code's hooks, so the user's
/// `config.toml` is never edited; it is only read to point out settings that would stop the
/// hooks from running.
public enum CodexSettings {
    /// Seconds Codex gives event hooks. They take milliseconds; this only bounds a hang.
    public static let eventTimeout = 5
    /// Codex caps `SessionEnd` hooks at 3 seconds.
    public static let sessionEndTimeout = 3
    /// Seconds Codex gives the permission hook: the 300 s wait plus slack.
    public static let permissionTimeout = 310

    public static let editor = MatcherGroupHooksEditor(
        agent: CodexHookAdapter.agentName,
        events: CodexHookAdapter.HookEvent.allCases.map { event in
            let timeout = switch event {
            case .permissionRequest: permissionTimeout
            case .sessionEnd: sessionEndTimeout
            default: eventTimeout
            }
            let matchesTools = switch event {
            case .preToolUse, .postToolUse, .permissionRequest: true
            default: false
            }
            return .init(name: event.rawValue, timeout: timeout, matchesTools: matchesTools)
        }
    )

    /// The `config.toml` next to a `hooks.json`.
    public static func configURL(besideHooksAt hooksURL: URL) -> URL {
        hooksURL.deletingLastPathComponent().appendingPathComponent("config.toml", isDirectory: false)
    }

    /// Problems in `config.toml` text that affect Liova's hooks.
    public static func warnings(configTOML text: String) -> [String] {
        let scan = CodexConfigScan(text)
        var warnings: [String] = []
        if scan.hooksDisabled {
            warnings.append(
                "Codex hooks are turned off in config.toml ([features] hooks = false). "
                    + "Remove that line, or set it to true, for Liova to see Codex."
            )
        }
        if scan.hasInlineHooks {
            warnings.append(
                "config.toml also defines hooks inline ([hooks]). Codex runs both, but warns at "
                    + "startup when one folder uses both forms."
            )
        }
        return warnings
    }
}

/// A conservative, read-only look at Codex's `config.toml`: just enough TOML to find the
/// `hooks` feature flag and inline hook tables. Anything it doesn't understand is skipped.
struct CodexConfigScan {
    private(set) var hooksDisabled = false
    private(set) var hasInlineHooks = false

    init(_ text: String) {
        var table = ""
        var inMultilineString = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip the body of multi-line strings: it can hold anything, including "[hooks]".
            let quotes = ["\"\"\"", "'''"].reduce(0) { $0 + line.components(separatedBy: $1).count - 1 }
            if inMultilineString {
                if quotes % 2 == 1 {
                    inMultilineString = false
                }
                continue
            }
            if quotes % 2 == 1 {
                inMultilineString = true
                continue
            }
            if line.hasPrefix("[") {
                table = Self.tableName(line)
                if table == "hooks" || table.hasPrefix("hooks.") {
                    hasInlineHooks = true
                }
                continue
            }
            guard let (key, value) = Self.keyValue(line) else { continue }
            let fullKey = table.isEmpty ? key : "\(table).\(key)"
            if ["features.hooks", "features.codex_hooks"].contains(fullKey), value == "false" {
                hooksDisabled = true
            }
            if table.isEmpty, key == "hooks" || key.hasPrefix("hooks.") {
                hasInlineHooks = true
            }
        }
    }

    /// `features` for `[features]`, `hooks.PreToolUse` for `[[hooks.PreToolUse]]`.
    private static func tableName(_ line: String) -> String {
        let withoutComment = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? line
        return withoutComment
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) }
            .joined(separator: ".")
    }

    /// A bare `key = value` line, with the key's quotes and the value's comment removed.
    private static func keyValue(_ line: String) -> (String, String)? {
        guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals]
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) }
            .joined(separator: ".")
        var value = String(line[line.index(after: equals)...])
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        return (key, value.trimmingCharacters(in: .whitespaces))
    }
}
