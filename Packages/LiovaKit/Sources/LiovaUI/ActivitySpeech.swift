import Foundation
import LiovaPluginKit

extension Activity {
    /// How VoiceOver reads an activity: "Deploying, staging, 40%".
    var spokenSummary: String {
        var parts = [title]
        if let subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let progress {
            parts.append(progress.formatted(.percent.precision(.fractionLength(0))))
        }
        return parts.joined(separator: ", ")
    }
}
