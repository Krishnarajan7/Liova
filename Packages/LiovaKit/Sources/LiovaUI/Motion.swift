import SwiftUI

/// The single source of truth for Liova's motion.
///
/// Every animation in the app uses one of these. Open and close are critically
/// damped (`dampingFraction: 1`), so the notch never overshoots. Hover is a
/// gentle, nearly damped spring: a calm acknowledgement, not a wobble.
///
/// Content follows the shape, never leads it: it leaves fast, before the shape
/// moves, and arrives only once the shape is close to its final size. That way
/// nothing is ever drawn outside the notch mid-animation.
public enum Motion {
    public static let open = Animation.spring(response: 0.42, dampingFraction: 1.0)
    /// Slightly quicker than open and just shy of critical damping: it settles cleanly without
    /// the slow tail a fully damped spring has at the end of a close.
    public static let close = Animation.spring(response: 0.36, dampingFraction: 0.92)
    public static let hover = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// The open notch growing or shrinking to fit new content (a page switch, lyrics
    /// appearing): settled, like open, so the edge never bounces past the content.
    public static let resize = Animation.spring(response: 0.38, dampingFraction: 1.0)

    /// Items joining or leaving a list (timers, shelf files): lively but settled.
    public static let list = Animation.spring(response: 0.38, dampingFraction: 0.8)

    /// How list items arrive and leave: they grow in from slightly small and fade, and
    /// shrink away when removed, so the rest of the list slides to make room.
    @MainActor public static var listItem: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.6).combined(with: .opacity),
            removal: .scale(scale: 0.6).combined(with: .opacity)
        )
    }

    /// Content leaving: quick, so it's gone before the shape changes much.
    public static let contentOut = Animation.easeOut(duration: 0.1)
    /// Expanded content arriving, once the opening shape has mostly grown.
    public static let expandedContentIn = Animation.easeOut(duration: 0.2).delay(0.12)
    /// Compact content arriving, once a closing shape has mostly shrunk.
    public static let compactContentIn = Animation.easeOut(duration: 0.18).delay(0.26)

    /// Runs `body` with animations disabled.
    ///
    /// Use for streaming values (scrubbers, volume, progress) so each update
    /// lands immediately instead of starting a new spring.
    @MainActor
    public static func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}
