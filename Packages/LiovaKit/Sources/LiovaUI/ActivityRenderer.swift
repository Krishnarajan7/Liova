import LiovaPluginKit
import SwiftUI

/// Custom views for one source's activities.
///
/// Features with richer content than a title and progress (Now Playing's artwork and
/// controls, for example) register a renderer for their source. Anything that returns
/// `nil` falls back to Liova's default views, so plugins never need one.
@MainActor
public protocol ActivityRenderer: AnyObject {
    /// The left "ear" of the closed notch.
    func compactLeading(for activity: Activity) -> AnyView?
    /// The right "ear" of the closed notch.
    func compactTrailing(for activity: Activity) -> AnyView?
    /// Drawn behind the ears, across the whole closed notch (clipped to its shape).
    /// For one-shot effects only: the closed notch never loops an animation.
    func compactBackground(for activity: Activity) -> AnyView?
    /// Whether the closed notch grows a strip under the camera row for `compactDetail`.
    /// Read on every layout pass, so it must be cheap, and it should change only when the
    /// strip comes or goes (not with each new line), so the notch isn't re-laid out for text.
    func showsCompactDetail(for activity: Activity) -> Bool
    /// One line of text in that strip (the lyric being sung).
    func compactDetail(for activity: Activity) -> AnyView?
    /// The main card of the open notch, when this activity is the visible one.
    func expanded(for activity: Activity) -> AnyView?
    /// True when the expanded card needs the whole open notch (e.g. a prompt the user must
    /// read and answer), so the queue of other activities is hidden beneath it.
    func expandedNeedsFullHeight(for activity: Activity) -> Bool
}

public extension ActivityRenderer {
    func compactLeading(for _: Activity) -> AnyView? {
        nil
    }

    func compactTrailing(for _: Activity) -> AnyView? {
        nil
    }

    func compactBackground(for _: Activity) -> AnyView? {
        nil
    }

    func showsCompactDetail(for _: Activity) -> Bool {
        false
    }

    func compactDetail(for _: Activity) -> AnyView? {
        nil
    }

    func expanded(for _: Activity) -> AnyView? {
        nil
    }

    func expandedNeedsFullHeight(for _: Activity) -> Bool {
        false
    }
}

/// Renderers keyed by activity source. Filled once at launch by the app.
@MainActor
public final class ActivityRendererRegistry {
    private var renderers: [String: any ActivityRenderer] = [:]

    public init() {}

    public func register(_ renderer: any ActivityRenderer, forSource source: String) {
        renderers[source] = renderer
    }

    func renderer(for activity: Activity) -> (any ActivityRenderer)? {
        renderers[activity.source]
    }

    /// Whether the closed notch should show `activity`'s detail strip.
    func showsCompactDetail(for activity: Activity?) -> Bool {
        guard let activity else { return false }
        return renderer(for: activity)?.showsCompactDetail(for: activity) ?? false
    }
}
