import Foundation
import LiovaPluginKit
@testable import LiovaUI
import Testing

struct ActivitySpeechTests {
    @Test func readsTitleSubtitleAndProgressAsOneSentence() {
        let activity = Activity(id: "build", source: "ci", title: "Deploying", subtitle: "staging", progress: 0.4)
        let percent = 0.4.formatted(.percent.precision(.fractionLength(0)))
        #expect(activity.spokenSummary == "Deploying, staging, \(percent)")
    }

    @Test func leavesOutWhatIsNotThere() {
        #expect(Activity(id: "a", source: "s", title: "Timer").spokenSummary == "Timer")
        #expect(Activity(id: "a", source: "s", title: "Timer", subtitle: "").spokenSummary == "Timer")
    }
}
