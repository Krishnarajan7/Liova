import Foundation

/// Pure, human-friendly output for `liova agents ...`.
public enum AgentCLIOutput {
    /// What an install or uninstall did (or, with `dryRun`, would do).
    public static func report(
        for plan: AgentInstallPlan,
        agent: AgentKind,
        result: AgentInstallResult?,
        dryRun: Bool
    ) -> String {
        let path = plan.targetURL.path(percentEncoded: false)
        let name = agent.displayName
        guard plan.needsWrite else {
            return switch plan.operation {
            case .install: "Liova's \(name) hooks are already installed and up to date in \(path). Nothing to change."
            case .uninstall: "Liova's \(name) hooks aren't installed in \(path). Nothing to change."
            }
        }
        var lines = [headline(for: plan, name: name, dryRun: dryRun)]
        lines += changeLines(plan.changes, dryRun: dryRun)
        if plan.operation == .install {
            lines.append("Each hook runs: \(plan.command)")
        }
        if dryRun, plan.original != nil {
            lines.append("A backup of the current file would be saved next to it first.")
        }
        if let backup = result?.backupURL {
            lines.append("Backup of the previous file: \(backup.path(percentEncoded: false))")
        }
        if !dryRun, plan.operation == .install {
            lines.append("")
            lines += nextSteps(agent)
        }
        return lines.joined(separator: "\n")
    }

    /// What to do after installing, and what to expect from the notch.
    private static func nextSteps(_ agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode:
            [
                "Start a new Claude Code session to pick up the hooks. Sessions that are already running",
                "may ask you to review the change in /hooks first.",
            ]
        case .codex:
            [
                "Start a new Codex session. Codex runs new or changed hooks only after you trust them:",
                "review and trust Liova's hooks when Codex asks, or in its /hooks menu.",
            ]
        case .geminiCLI:
            [
                "Start a new Gemini CLI session to pick up the hooks.",
                "Gemini CLI doesn't let hooks answer its permission prompts, so the notch shows when it's",
                "waiting for you and you approve in the terminal.",
            ]
        case .cursor:
            [
                "Cursor reloads hooks.json by itself; restart Cursor if nothing shows up.",
                "Cursor's hooks can't reliably approve actions, so the notch shows what the agent is doing",
                "and you approve in Cursor.",
            ]
        }
    }

    private static func headline(for plan: AgentInstallPlan, name: String, dryRun: Bool) -> String {
        let path = plan.targetURL.path(percentEncoded: false)
        let install = plan.operation == .install
        if dryRun {
            let newFile = plan.original == nil ? " (new file)" : ""
            return "Dry run: nothing was written.\n"
                + "Would \(install ? "install" : "remove") Liova's \(name) hooks in \(path)\(newFile)."
        }
        return install ? "Installed Liova's \(name) hooks in \(path)." : "Removed Liova's \(name) hooks from \(path)."
    }

    private static func changeLines(_ changes: [AgentHookChange], dryRun: Bool) -> [String] {
        [AgentHookChange.Kind.added, .updated, .removed].compactMap { kind in
            let events = changes.filter { $0.kind == kind }.map(\.event)
            return events.isEmpty ? nil : "  \(label(kind, dryRun: dryRun)): \(events.joined(separator: ", "))"
        }
    }

    private static func label(_ kind: AgentHookChange.Kind, dryRun: Bool) -> String {
        switch kind {
        case .added: dryRun ? "Add" : "Added"
        case .updated: dryRun ? "Update" : "Updated"
        case .removed: dryRun ? "Remove" : "Removed"
        case .unchanged: "Unchanged"
        }
    }

    /// The `liova agents status` report for one agent.
    public static func status(_ status: AgentHookStatus, agent: AgentKind, settingsPath: String) -> String {
        var lines: [String] = []
        switch status.state {
        case .installed:
            lines.append("\(agent.displayName): installed (\(settingsPath))")
        case .notInstalled:
            lines.append("\(agent.displayName): not installed (\(settingsPath))")
            lines.append("  Set it up with: liova agents install \(agent.rawValue)")
        case .outdated:
            lines.append("\(agent.displayName): outdated (\(settingsPath))")
            lines += status.problems.map { "  - \($0)" }
            lines.append("  Fix it with: liova agents install \(agent.rawValue)")
        }
        lines += status.warnings.map { "  Warning: \($0)" }
        return lines.joined(separator: "\n")
    }
}
