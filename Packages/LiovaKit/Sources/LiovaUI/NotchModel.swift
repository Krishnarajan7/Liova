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
    /// The open notch's selected page. Kept across openings, reset to Home when something
    /// needs the user (e.g. an agent asking for permission).
    public internal(set) var selectedPage = NotchChrome.homePageID

    init(geometry: NotchGeometry, showsIdleVirtualNotch: Bool) {
        self.geometry = geometry
        self.showsIdleVirtualNotch = showsIdleVirtualNotch
    }
}
