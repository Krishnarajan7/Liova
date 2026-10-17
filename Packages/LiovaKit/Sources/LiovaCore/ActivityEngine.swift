import Foundation
import LiovaPluginKit
import Observation

/// Decides what the notch shows.
///
/// The engine is a priority stack. The visible activity is the one with the highest
/// priority; among equal priorities the most recently *started* one wins. Updating an
/// activity never changes its place in the stack, so a progress tick cannot steal focus.
/// When an activity ends or expires, the one beneath it is restored automatically.
///
/// Expiry is event-driven: one task sleeps until the next deadline. Nothing polls.
@MainActor
@Observable
public final class ActivityEngine {
    public struct Limits: Sendable {
        public var maxActivitiesPerSource: Int
        public var maxActivities: Int

        public init(maxActivitiesPerSource: Int = 16, maxActivities: Int = 64) {
            self.maxActivitiesPerSource = maxActivitiesPerSource
            self.maxActivities = maxActivities
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case alreadyExpired
        case tooManyForSource(String)
        case tooManyActivities
        case notFound(ActivityID)
    }

    /// All live activities in display order. The first one is visible.
    public private(set) var activities: [Activity] = []

    /// The activity the notch is showing, if any.
    public var current: Activity? {
        activities.first
    }

    @ObservationIgnored private var startSequence: [ActivityID: UInt64] = [:]
    @ObservationIgnored private var nextSequence: UInt64 = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let limits: Limits
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(limits: Limits = Limits(), now: @escaping @Sendable () -> Date = Date.init) {
        self.limits = limits
        self.now = now
    }

    // MARK: - Mutations

    /// Starts an activity, or updates it in place if one with the same ID is live.
    public func start(_ activity: Activity) throws(Failure) {
        if let expiresAt = activity.expiresAt, expiresAt <= now() {
            throw .alreadyExpired
        }
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            guard activities[index] != activity else { return }
            var updated = activities
            updated[index] = activity
            commit(updated)
            Log.activity.debug("Updated \(activity.id, privacy: .public)")
            return
        }
        guard activities.count < limits.maxActivities else { throw .tooManyActivities }
        let fromSource = activities.lazy.filter { $0.source == activity.source }.count
        guard fromSource < limits.maxActivitiesPerSource else { throw .tooManyForSource(activity.source) }

        nextSequence += 1
        startSequence[activity.id] = nextSequence
        commit(activities + [activity])
        Log.activity.debug("Started \(activity.id, privacy: .public) from \(activity.source, privacy: .public)")
    }

    /// Applies `change` to a live activity without moving it in the stack.
    public func update(_ id: ActivityID, _ change: (inout Activity) -> Void) throws(Failure) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        var activity = activities[index]
        change(&activity)
        activity.id = id // identity is not editable
        try start(activity)
    }

    public func end(_ id: ActivityID) {
        guard activities.contains(where: { $0.id == id }) else { return }
        startSequence[id] = nil
        commit(activities.filter { $0.id != id })
        Log.activity.debug("Ended \(id, privacy: .public)")
    }

    public func endAll(source: String) {
        let ended = activities.filter { $0.source == source }
        guard !ended.isEmpty else { return }
        for activity in ended {
            startSequence[activity.id] = nil
        }
        commit(activities.filter { $0.source != source })
    }

    public func activity(_ id: ActivityID) -> Activity? {
        activities.first { $0.id == id }
    }

    /// Removes every activity whose deadline has passed. Called by the expiry task;
    /// exposed for tests and for callers that know the clock jumped (e.g. after sleep).
    public func purgeExpired() {
        let date = now()
        let live = activities.filter { ($0.expiresAt ?? .distantFuture) > date }
        guard live.count != activities.count else { return }
        for activity in activities where !live.contains(where: { $0.id == activity.id }) {
            startSequence[activity.id] = nil
        }
        commit(live)
    }

    // MARK: - Internals

    private func commit(_ candidates: [Activity]) {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            return startSequence[lhs.id, default: 0] > startSequence[rhs.id, default: 0]
        }
        // Writing an equal array would still notify observers; skip it.
        if sorted != activities {
            activities = sorted
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let deadline = activities.compactMap(\.expiresAt).min() else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(20))
            guard !Task.isCancelled else { return }
            self?.purgeExpired()
        }
    }
}
