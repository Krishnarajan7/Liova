import LiovaCore
import Observation

/// Per-display view state. Kept separate from the activity engine so a pointer
/// change re-renders only what reads `presentation`.
@MainActor
@Observable
public final class NotchModel {
    public internal(set) var presentation: NotchPresentation = .closed
    public internal(set) var geometry: NotchGeometry
    public internal(set) var showsIdleVirtualNotch: Bool

    init(geometry: NotchGeometry, showsIdleVirtualNotch: Bool) {
        self.geometry = geometry
        self.showsIdleVirtualNotch = showsIdleVirtualNotch
    }
}
