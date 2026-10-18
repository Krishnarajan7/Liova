@testable import LiovaProviders
import Testing

struct CaptureMonitorSmokeTests {
    @MainActor
    @Test func readsDevicesWithoutCrashing() {
        // Device lists vary by Mac; this only checks the system calls succeed.
        _ = SystemCaptureMonitor.audioInputDevices().map(SystemCaptureMonitor.isAudioDeviceRunning)
        _ = SystemCaptureMonitor.cameras().map(SystemCaptureMonitor.isCameraRunning)
    }
}
