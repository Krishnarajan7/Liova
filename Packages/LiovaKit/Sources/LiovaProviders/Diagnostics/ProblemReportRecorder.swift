import Foundation
import MetricKit
import os

/// Saves what MetricKit reports about Liova (crashes, hangs, runaway CPU or disk use) to
/// `~/Library/Logs/Liova`, so someone filing an issue has something to attach.
///
/// Nothing is sent anywhere. macOS delivers these on its own schedule, a crash usually the
/// next time Liova starts, and calls back off the main thread.
public final class ProblemReportRecorder: NSObject, MXMetricManagerSubscriber, Sendable {
    private let store: ProblemReportStore
    private static let log = Logger(subsystem: "app.liova.Liova", category: "diagnostics")

    public init(store: ProblemReportStore = ProblemReportStore()) {
        self.store = store
    }

    public func start() {
        MXMetricManager.shared.add(self)
    }

    public func stop() {
        MXMetricManager.shared.remove(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let kind = Self.kind(
                crashes: payload.crashDiagnostics?.count ?? 0,
                hangs: payload.hangDiagnostics?.count ?? 0
            )
            do {
                try store.save(payload.jsonRepresentation(), kind: kind, at: payload.timeStampEnd)
                Self.log.notice("Saved a \(kind, privacy: .public) report")
            } catch {
                Self.log.error("Couldn't save a problem report: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What a saved report is named after: the most serious thing in it.
    static func kind(crashes: Int, hangs: Int) -> String {
        if crashes > 0 {
            return "crash"
        }
        return hangs > 0 ? "hang" : "diagnostic"
    }
}
