import Observation

/// Re-runs `onChange` every time a value read in `track` changes, until the loop is released.
@MainActor
final class ObservationLoop {
    private let track: @MainActor () -> Void
    private let onChange: @MainActor () -> Void

    init(track: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        self.track = track
        self.onChange = onChange
        observe()
    }

    private func observe() {
        withObservationTracking(track) { [weak self] in
            // Called before the change is applied; react on the next main-actor turn.
            Task { @MainActor in
                // Once the loop is released, `self` is nil and observation stops.
                guard let self else { return }
                self.onChange()
                self.observe()
            }
        }
    }
}
