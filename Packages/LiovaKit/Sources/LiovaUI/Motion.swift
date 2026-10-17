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
    public static let close = Animation.spring(response: 0.45, dampingFraction: 1.0)
    public static let hover = Animation.spring(response: 0.3, dampingFraction: 0.86)

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
