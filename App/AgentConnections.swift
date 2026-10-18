import AppKit
import Observation

/// Connects coding agents to Agent Island from Settings, using the `liova` CLI bundled in
/// `Liova.app/Contents/Helpers`. The CLI's installer does the work (backup, atomic write,
/// only Liova's own entries), so Settings is just buttons around it.
@MainActor
@Observable
final class AgentConnections {
    enum Status: Equatable {
        case checking
        case connected
        /// Hooks are installed but run a different copy of `liova` (e.g. an older install).
        case connectedElsewhere
        case notConnected
        case failed(String)
    }

    struct Agent: Identifiable {
        let id: String
        let name: String
        let approvals: Bool
    }

    static let agents = [
        Agent(id: "claude-code", name: "Claude Code", approvals: true),
        Agent(id: "codex", name: "Codex", approvals: true),
        Agent(id: "gemini-cli", name: "Gemini CLI", approvals: false),
        Agent(id: "cursor", name: "Cursor", approvals: false),
    ]

    private(set) var statuses: [String: Status] = [:]
    private(set) var busy: Set<String> = []

    /// The bundled CLI, or nil in builds that skipped `make bundle-cli`.
    var helper: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "liova")
    }

    /// Hooks point at the CLI inside the app, so the app should live somewhere stable.
    var isInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    func refresh() {
        for agent in Self.agents {
            statuses[agent.id] = .checking
            Task { await refresh(agent.id) }
        }
    }

    func connect(_ id: String) {
        Task { await run(["agents", "install", id], for: id) }
    }

    func disconnect(_ id: String) {
        Task { await run(["agents", "uninstall", id], for: id) }
    }

    private func refresh(_ id: String) async {
        guard let helper else {
            statuses[id] = .failed("This build doesn't include the liova helper.")
            return
        }
        let result = await Self.execute(helper, ["agents", "status", id])
        statuses[id] = if result.status == 0 {
            .connected
        } else if result.output.contains(": outdated") {
            .connectedElsewhere
        } else {
            .notConnected
        }
    }

    private func run(_ arguments: [String], for id: String) async {
        guard let helper else { return }
        busy.insert(id)
        let result = await Self.execute(helper, arguments)
        busy.remove(id)
        if result.status != 0 {
            let message = result.output.split(separator: "\n").last.map(String.init) ?? "Something went wrong."
            statuses[id] = .failed(message)
            return
        }
        await refresh(id)
    }

    /// Runs the helper off the main thread and returns its exit status and combined output.
    nonisolated static func execute(
        _ helper: URL,
        _ arguments: [String]
    ) async -> (status: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = helper
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }
}
