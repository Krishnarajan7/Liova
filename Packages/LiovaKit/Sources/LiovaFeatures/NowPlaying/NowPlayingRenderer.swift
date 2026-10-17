import LiovaPluginKit
import LiovaUI
import SwiftUI

/// Draws the media activity: artwork and a live indicator when closed, and a full
/// player with scrubber and controls when open.
@MainActor
public final class NowPlayingRenderer: ActivityRenderer {
    private let feature: NowPlayingFeature

    public init(feature: NowPlayingFeature) {
        self.feature = feature
    }

    public func compactLeading(for _: Activity) -> AnyView? {
        AnyView(ArtworkView(feature: feature, size: 22, cornerRadius: 6))
    }

    public func compactTrailing(for _: Activity) -> AnyView? {
        AnyView(PlayingIndicator(feature: feature))
    }

    public func expanded(for _: Activity) -> AnyView? {
        AnyView(NowPlayingCard(feature: feature))
    }
}

private struct ArtworkView: View {
    let feature: NowPlayingFeature
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let artwork = feature.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.white.opacity(0.1))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.pink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: feature.artwork != nil)
    }
}

/// Bouncing bars while playing, a pause glyph while paused.
///
/// The bars are Core Animation layers that the window server animates on its own, so music
/// playing with the notch closed stays within the 0.5% CPU budget (see `EqualizerBars`).
private struct PlayingIndicator: View {
    let feature: NowPlayingFeature

    var body: some View {
        let isPlaying = feature.info?.isPlaying ?? false
        ZStack {
            EqualizerBars(isAnimating: isPlaying && feature.animatesIndicator, color: .systemPink)
                .frame(width: 16, height: 13)
                .opacity(isPlaying ? 1 : 0)
            Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .opacity(isPlaying ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: isPlaying)
    }
}

private struct NowPlayingCard: View {
    let feature: NowPlayingFeature

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(feature: feature, size: 60, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.info?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(feature.info?.artist ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Scrubber(feature: feature)
                    .padding(.top, 6)
            }
            Controls(feature: feature)
        }
    }
}

private struct Controls: View {
    let feature: NowPlayingFeature

    var body: some View {
        HStack(spacing: 2) {
            ControlButton(symbol: "backward.fill", size: 14) { feature.previousTrack() }
            ControlButton(symbol: feature.info?.isPlaying == true ? "pause.fill" : "play.fill", size: 20) {
                feature.togglePlayPause()
            }
            ControlButton(symbol: "forward.fill", size: 14) { feature.nextTrack() }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(isHovered ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// Elapsed / remaining time and a seekable bar.
///
/// While playing it redraws twice a second (enough for a one-second clock and a bar that
/// moves a pixel at a time); while paused, or when the notch is closed, it doesn't redraw.
private struct Scrubber: View {
    let feature: NowPlayingFeature
    @State private var dragFraction: Double?

    var body: some View {
        let isPlaying = feature.info?.isPlaying ?? false
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(at: isPlaying ? context.date : .now)
        }
        .disabled(feature.info?.duration == nil)
    }

    private func content(at date: Date) -> some View {
        let duration = feature.info?.duration ?? 0
        let elapsed = feature.info?.elapsed(at: date) ?? 0
        let fraction = dragFraction ?? (duration > 0 ? elapsed / duration : 0)
        let shownElapsed = dragFraction.map { $0 * duration } ?? elapsed

        return VStack(spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(dragFraction == nil ? 0.85 : 1))
                        .frame(width: max(4, proxy.size.width * fraction))
                }
                .frame(height: dragFraction == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                        }
                        .onEnded { value in
                            feature.seek(toFraction: min(max(value.location.x / proxy.size.width, 0), 1))
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.12), value: dragFraction == nil)

            HStack {
                Text(NowPlayingPolicy.format(shownElapsed))
                Spacer()
                Text("-" + NowPlayingPolicy.format(max(0, duration - shownElapsed)))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
        .transaction { $0.animation = nil }
    }
}
