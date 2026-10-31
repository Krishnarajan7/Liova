import AppKit
import LiovaCore
import LiovaProviders
import SwiftUI

/// Repeat in the player: off, all, one. Shown only for players that report repeat, so it's
/// never a button that does nothing.
struct RepeatButton: View {
    let feature: NowPlayingFeature
    let mode: RepeatMode
    @State private var isHovered = false

    var body: some View {
        Button {
            feature.cycleRepeat()
        } label: {
            PlayerToggleGlyph(
                symbol: mode == .one ? "repeat.1" : "repeat", isOn: mode != .off, isLit: mode != .off,
                isHovered: isHovered
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(Text("Repeat"))
        .accessibilityValue(Text(help))
    }

    private var help: String {
        switch mode {
        case .off: "Repeat is off"
        case .all: "Repeating all"
        case .one: "Repeating this song"
        }
    }
}

/// The player's small on/off buttons (lyrics, repeat): a thin glyph that turns pink with a
/// dot beneath when on, as in Music. Same size for all, so they sit as a pair.
struct PlayerToggleGlyph: View {
    let symbol: String
    let isOn: Bool
    /// On and doing something (lyrics found, repeat set): coloured. On but idle: just the dot.
    let isLit: Bool
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isLit ? Color.pink : .white.opacity(isHovered ? 0.85 : 0.5))
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 13)
            Circle()
                .fill(isLit ? Color.pink : .white.opacity(0.5))
                .frame(width: 3, height: 3)
                .opacity(isOn ? 1 : 0)
        }
        .frame(width: 26, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(isHovered ? 0.1 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isOn)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// Which way a finger swipe went.
enum SwipeDirection: Equatable {
    case left, right
}

/// Turns a trackpad's scroll events into at most one swipe per gesture. Pure, so it's tested.
///
/// Counts only the fingers on the trackpad (not the momentum that follows), in the direction
/// the fingers moved whatever the natural-scrolling setting, and only a clearly sideways
/// movement, so scrolling up or down never skips a song.
struct SwipeTracker {
    /// How far the fingers travel sideways, in points, before it counts.
    static let threshold: CGFloat = 60

    private var travel: CGSize = .zero
    private var fired = false

    /// `began` and `ended` bracket one gesture. `inverted` is the event's
    /// `isDirectionInvertedFromDevice` (natural scrolling).
    mutating func add(
        deltaX: CGFloat, deltaY: CGFloat, inverted: Bool, began: Bool, ended: Bool
    ) -> SwipeDirection? {
        if began {
            travel = .zero
            fired = false
        }
        // With natural scrolling the delta runs opposite to the fingers (content moves the
        // other way); without, it follows them. Checked on a MacBook trackpad.
        travel.width += inverted ? -deltaX : deltaX
        travel.height += abs(deltaY)
        defer {
            if ended {
                travel = .zero
                fired = false
            }
        }
        guard !fired, abs(travel.width) >= Self.threshold, abs(travel.width) > travel.height * 1.5 else {
            return nil
        }
        fired = true
        return travel.width > 0 ? .right : .left
    }
}

extension View {
    /// Two-finger swipe right for the next song, left for the previous one, with a nudge
    /// in that direction and a tick on trackpads that can.
    func trackSwipe(_ feature: NowPlayingFeature) -> some View {
        modifier(TrackSwipe(feature: feature))
    }
}

private struct TrackSwipe: ViewModifier {
    let feature: NowPlayingFeature
    @State private var nudge: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: nudge)
            .background(SwipeCatcher { direction in
                switch direction {
                case .right: feature.nextTrack()
                case .left: feature.previousTrack()
                }
                if feature.hapticsEnabled {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
                    nudge = direction == .right ? 14 : -14
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.12)) {
                    nudge = 0
                }
            })
    }
}

/// Watches scroll events over its own area of the window. Draws nothing and takes no clicks.
private struct SwipeCatcher: NSViewRepresentable {
    let onSwipe: (SwipeDirection) -> Void

    func makeNSView(context _: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context _: Context) {
        view.onSwipe = onSwipe
    }

    final class CatcherView: NSView {
        var onSwipe: ((SwipeDirection) -> Void)?
        private var monitor: Any?
        private var tracker = SwipeTracker()

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            // Only while the card is in a window, so a closed notch listens to nothing.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            // Fingers on a trackpad only: not a mouse wheel, not the momentum afterwards.
            guard event.window === window, event.momentumPhase.isEmpty, !event.phase.isEmpty,
                  bounds.contains(convert(event.locationInWindow, from: nil))
            else { return }
            if event.phase.contains(.began) {
                Log.interaction.notice("Player swipe: gesture started")
            }
            let direction = tracker.add(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                inverted: event.isDirectionInvertedFromDevice,
                began: event.phase.contains(.began),
                ended: event.phase.contains(.ended) || event.phase.contains(.cancelled)
            )
            if let direction {
                Log.interaction.notice("Player swipe: \(direction == .right ? "next" : "previous", privacy: .public)")
                onSwipe?(direction)
            }
        }
    }
}
