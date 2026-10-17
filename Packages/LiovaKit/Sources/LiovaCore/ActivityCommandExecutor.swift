import LiovaPluginKit

/// Applies plugin commands (from the socket, the CLI or `liova://` URLs) to the engine.
///
/// This is the trust boundary between outside callers and the notch:
/// - `system.*` activities belong to built-in features and can't be touched.
/// - A start can't take over an ID that another source owns.
/// - URL commands are low-trust (any web page can open a URL), so they may only
///   change activities that URLs created.
@MainActor
public final class ActivityCommandExecutor {
    /// Where a command came from.
    public enum Origin: Sendable {
        /// The local socket: a process running as the current user.
        case socket
        /// A `liova://` URL, which any app or web page can open.
        case url(source: String)
    }

    private let engine: ActivityEngine

    public init(engine: ActivityEngine) {
        self.engine = engine
    }

    public func execute(_ command: IPCCommand, origin: Origin) -> IPCResponse {
        let response = run(command, origin: origin)
        if let error = response.error {
            Log.activity.notice("Rejected \(command.op.rawValue, privacy: .public): \(error.message, privacy: .public)")
        }
        return response
    }

    private func run(_ command: IPCCommand, origin: Origin) -> IPCResponse {
        switch command {
        case .ping: .success()
        case let .start(activity): start(activity, origin: origin)
        case let .update(patch): update(patch, origin: origin)
        case let .end(id): end(id, origin: origin)
        case let .endAll(source): endAll(source: source, origin: origin)
        case .list: .success(activities: engine.activities)
        // Agent commands are routed to Agent Island before they reach the executor.
        case .agentEvent, .agentPermission: .failure(.unavailable, "Agent Island isn't available.")
        }
    }

    private func start(_ activity: Activity, origin: Origin) -> IPCResponse {
        if let denied = denyIfNotAllowed(source: activity.source, origin: origin) {
            return denied
        }
        if let existing = engine.activity(activity.id), existing.source != activity.source {
            return .failure(.forbidden, "Activity '\(activity.id)' belongs to another source.")
        }
        return perform { () throws(ActivityEngine.Failure) in try engine.start(activity) }
    }

    private func update(_ patch: ActivityPatch, origin: Origin) -> IPCResponse {
        guard let existing = engine.activity(patch.id) else { return notFound(patch.id) }
        if let denied = denyIfNotAllowed(source: existing.source, origin: origin) {
            return denied
        }
        var updated = patch.applied(to: existing)
        updated.id = existing.id
        updated.source = existing.source
        return perform { () throws(ActivityEngine.Failure) in try engine.start(updated) }
    }

    private func end(_ id: ActivityID, origin: Origin) -> IPCResponse {
        guard let existing = engine.activity(id) else { return notFound(id) }
        if let denied = denyIfNotAllowed(source: existing.source, origin: origin) {
            return denied
        }
        engine.end(id)
        return .success()
    }

    private func endAll(source: String, origin: Origin) -> IPCResponse {
        if let denied = denyIfNotAllowed(source: source, origin: origin) {
            return denied
        }
        engine.endAll(source: source)
        return .success()
    }

    private func denyIfNotAllowed(source: String, origin: Origin) -> IPCResponse? {
        if LiovaValidation.isReservedSource(source) {
            return .failure(.forbidden, "Activities from '\(source)' are managed by Liova itself.")
        }
        if case let .url(urlSource) = origin, source != urlSource {
            return .failure(.forbidden, "Links can only change activities that links created.")
        }
        return nil
    }

    private func perform(_ body: () throws(ActivityEngine.Failure) -> Void) -> IPCResponse {
        do {
            try body()
            return .success()
        } catch {
            return switch error {
            case .alreadyExpired:
                .failure(.badRequest, "The activity has already expired.")
            case let .tooManyForSource(source):
                .failure(.rateLimited, "Too many live activities from '\(source)'. End some first.")
            case .tooManyActivities:
                .failure(.busy, "Too many live activities. Try again later.")
            case let .notFound(id):
                notFound(id)
            }
        }
    }

    private func notFound(_ id: ActivityID) -> IPCResponse {
        .failure(.notFound, "No live activity with ID '\(id)'.")
    }
}
