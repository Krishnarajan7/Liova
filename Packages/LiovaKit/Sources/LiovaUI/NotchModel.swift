import CoreGraphics
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
    /// True while the open content should stay mounted: when open, and for a moment after
    /// closing so a quick re-hover can reverse the animation instead of rebuilding views.
    public internal(set) var keepsExpandedContent = false
    /// A full-screen app (a movie, a game) covers this display. The notch stays out of the
    /// way until hovered, and nothing in it animates.
    public internal(set) var isCoveredByFullScreen = false
    /// Files are being dragged toward the notch; pages can show drop targets.
    public internal(set) var isFileDragActive = false
    /// How much of the open notch below the camera row its content needs, as last measured.
    /// The open notch fits around it; nil (not measured yet) means full height.
    public internal(set) var expandedContentHeight: CGFloat?

    /// What the open notch should fit: full height while files are dragged in, so drop
    /// targets are big, otherwise the measured content.
    var fittedContentHeight: CGFloat? {
        isFileDragActive ? nil : expandedContentHeight
    }

    init(geometry: NotchGeometry, showsIdleVirtualNotch: Bool) {
        self.geometry = geometry
        self.showsIdleVirtualNotch = showsIdleVirtualNotch
    }
}
