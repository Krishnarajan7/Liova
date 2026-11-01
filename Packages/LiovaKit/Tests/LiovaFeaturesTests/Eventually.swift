import Foundation

/// Polls `condition` on the main actor until it holds or `timeout` passes. For work a feature
/// finishes in a background task: a fixed sleep is too short on a busy CI machine.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
