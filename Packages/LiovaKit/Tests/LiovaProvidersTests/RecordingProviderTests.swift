import CoreGraphics
import Foundation
@testable import LiovaProviders
import Testing

struct OBSClientTests {
    @Test func answersTheChallengeLikeOBSExpects() {
        // Worked out independently: base64(sha256(base64(sha256(password + salt)) + challenge)).
        let answer = OBSClient.authentication(
            password: "supersecretpassword",
            salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
            challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
        )
        #expect(answer == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
    }

    @Test func readsTheRecordStatus() throws {
        let date = Date()
        let status: [String: Any] = ["outputActive": true, "outputPaused": true, "outputDuration": 95000]
        let recording = try #require(OBSClient.recording(from: status, at: date))
        #expect(recording.isPaused)
        #expect(recording.elapsed == 95)
        #expect(OBSClient.recording(from: ["outputActive": false], at: date) == nil)
    }
}

struct ScreenRecordingTests {
    @Test func theMenuBarStopButtonMeansRecording() {
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let stopButton: [String: Any] = [
            kCGWindowOwnerName as String: "screencaptureui",
            kCGWindowLayer as String: status,
        ]
        let toolbar: [String: Any] = [kCGWindowOwnerName as String: "screencaptureui", kCGWindowLayer as String: 0]
        let otherItem: [String: Any] = [
            kCGWindowOwnerName as String: "Control Centre",
            kCGWindowLayer as String: status,
        ]
        #expect(SystemScreenRecording.hasStopButton([toolbar, stopButton]))
        #expect(!SystemScreenRecording.hasStopButton([toolbar, otherItem]))
    }
}

@MainActor
struct GlobalHotkeysTests {
    @Test func registersAndReleasesShortcuts() {
        let hotkeys = GlobalHotkeys()
        // ⌃⌥⇧⌘F19: nothing else on a test machine uses it.
        let refused = hotkeys.register(["test": HotkeyCombo(keyCode: 80, modifiers: 0x1B00)]) { _ in }
        #expect(refused.isEmpty)
        hotkeys.unregisterAll()
    }
}
