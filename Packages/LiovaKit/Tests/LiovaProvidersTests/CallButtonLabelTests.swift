@testable import LiovaProviders
import Testing

struct CallButtonLabelTests {
    @Test func findsTheHangUpButton() {
        #expect(CallButtonLabels.isHangUp("Leave"))
        #expect(CallButtonLabels.isHangUp("Leave call"))
        #expect(CallButtonLabels.isHangUp("End Call"))
        #expect(CallButtonLabels.isHangUp("Hang Up…"))
        #expect(CallButtonLabels.isHangUp("\u{200E}End call"))
        #expect(!CallButtonLabels.isHangUp("Send"))
        #expect(!CallButtonLabels.isHangUp("Calendar"))
    }

    @Test func neverEndsTheMeetingForEveryone() {
        #expect(!CallButtonLabels.isHangUp("End Meeting for All"))
        #expect(!CallButtonLabels.isConfirmation("End meeting for all"))
        #expect(CallButtonLabels.isConfirmation("Leave Meeting"))
    }

    @Test func shortcutsOnlyForAppsThatHaveOne() {
        #expect(CallButtonLabels.shortcut(for: "com.microsoft.teams2") != nil)
        #expect(CallButtonLabels.shortcut(for: "us.zoom.xos") == nil)
    }
}
