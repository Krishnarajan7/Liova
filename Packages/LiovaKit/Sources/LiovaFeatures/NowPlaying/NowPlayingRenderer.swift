import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// Draws the media activity: artwork and a live indicator when closed (with the line being
/// sung under it, when lyrics are on), and a full player with scrubber and controls when open.
@MainActor
public final class NowPlayingRenderer: ActivityRenderer {
    private let feature: NowPlayingFeature
    private let lyrics: LyricsFeature?

    public init(feature: NowPlayingFeature, lyrics: LyricsFeature? = nil) {
        self.feature = feature
        self.lyrics = lyrics
    }

    public func compactLeading(for _: Activity) -> AnyView? {
        AnyView(ArtworkView(feature: feature, size: 22, cornerRadius: 6))
    }

    public func compactTrailing(for _: Activity) -> AnyView? {
        AnyView(PlayingIndicator(feature: feature, lyrics: lyrics))
    }

    public func showsCompactDetail(for _: Activity) -> Bool {
        lyrics?.showsCompactLine ?? false
    }

    public func compactDetail(for _: Activity) -> AnyView? {
        lyrics.map { AnyView(CompactLyricLine(feature: $0)) }
    }

    public func expanded(for _: Activity) -> AnyView? {
        AnyView(NowPlayingCard(feature: feature, lyrics: lyrics))
    }

    /// Lyrics take the room the queue of other activities would use.
    public func expandedNeedsFullHeight(for _: Activity) -> Bool {
        lyrics?.lyrics != nil
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
///
/// It also keeps the closed notch's lyric line in time: while it's on screen, lyrics schedule
/// their line changes (see `LyricsFeature`).
private struct PlayingIndicator: View {
    let feature: NowPlayingFeature
    let lyrics: LyricsFeature?
    @Environment(\.notchCompactVisible) private var compactVisible

    var body: some View {
        let isPlaying = feature.info?.isPlaying ?? false
        ZStack {
            EqualizerBars(isAnimating: isPlaying, mode: feature.musicBars, color: .systemPink)
                .frame(width: 16, height: 13)
                .opacity(isPlaying ? 1 : 0)
            Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .opacity(isPlaying ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: isPlaying)
        .modifier(LyricsViewer(feature: lyrics, isActive: compactVisible && lyrics?.isShownInClosedNotch == true))
    }
}

/// The line being sung, under the closed notch. A new line slides up, like the open card.
private struct CompactLyricLine: View {
    let feature: LyricsFeature

    var body: some View {
        let line = feature.compactLine
        ZStack {
            Text(line)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
                // Keyed by line, so a repeated line ("yeah, yeah") still moves on.
                .id(feature.lineIndex ?? -1)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 17)
        .clipped()
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: feature.lineIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line))
    }
}

/// Counts a view as showing lyrics while `isActive`, so line changes are scheduled only
/// while someone can see them. Balanced on every path: activation, deactivation, removal.
private struct LyricsViewer: ViewModifier {
    let feature: LyricsFeature?
    let isActive: Bool
    @State private var isRegistered = false

    func body(content: Content) -> some View {
        content
            .onAppear { register(isActive) }
            .onChange(of: isActive) { _, active in register(active) }
            .onDisappear { register(false) }
    }

    private func register(_ active: Bool) {
        guard let feature, active != isRegistered else { return }
        isRegistered = active
        if active {
            feature.viewerAppeared()
        } else {
            feature.viewerLeft()
        }
    }
}

private struct NowPlayingCard: View {
    let feature: NowPlayingFeature
    let lyrics: LyricsFeature?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            player
            if let lyrics, let synced = lyrics.lyrics {
                LyricsLines(feature: lyrics, lyrics: synced)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: lyrics?.lyrics != nil)
    }

    private var player: some View {
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
            Controls(feature: feature, lyrics: lyrics)
        }
    }
}

/// The line being sung and the next one. Changes slide up, like karaoke.
private struct LyricsLines: View {
    let feature: LyricsFeature
    let lyrics: SyncedLyrics

    var body: some View {
        let index = feature.lineIndex
        let current = index.map { lyrics.lines[$0].text }
        let nextIndex = (index ?? -1) + 1
        let next = nextIndex < lyrics.lines.count ? lyrics.lines[nextIndex].text : nil
        VStack(alignment: .leading, spacing: 2) {
            line(current, isCurrent: true)
                .id("current-\(index ?? -1)")
            line(next, isCurrent: false)
                .id("next-\(nextIndex)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: index)
        .onAppear { feature.viewerAppeared() }
        .onDisappear { feature.viewerLeft() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(current ?? ""))
    }

    private func line(_ text: String?, isCurrent: Bool) -> some View {
        // An empty line is an instrumental break.
        let shown = text.map { $0.isEmpty ? "♪" : $0 } ?? " "
        return Text(shown)
            .font(.system(size: isCurrent ? 13 : 11, weight: isCurrent ? .semibold : .medium, design: .rounded))
            .foregroundStyle(.white.opacity(isCurrent ? 0.95 : 0.4))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity.combined(with: .offset(y: -8))
            ))
    }
}

private struct Controls: View {
    let feature: NowPlayingFeature
    let lyrics: LyricsFeature?

    var body: some View {
        HStack(spacing: 2) {
            if let lyrics {
                LyricsToggle(feature: lyrics)
            }
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
        TimelineView(Self.schedule(isPlaying: isPlaying)) { context in
            content(at: context.date)
        }
        .disabled(feature.info?.duration == nil)
    }

    /// Ticks only while playing. A paused track's clock doesn't move, so it doesn't redraw.
    private static func schedule(isPlaying: Bool) -> ScrubberSchedule {
        ScrubberSchedule(interval: isPlaying ? 0.5 : nil)
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

/// Every `interval` seconds, or one single entry when `interval` is nil.
private struct ScrubberSchedule: TimelineSchedule {
    let interval: TimeInterval?

    func entries(from startDate: Date, mode _: Mode) -> AnyIterator<Date> {
        guard let interval else {
            var done = false
            return AnyIterator {
                defer { done = true }
                return done ? nil : startDate
            }
        }
        var next = startDate
        return AnyIterator {
            defer { next += interval }
            return next
        }
    }
}

/// Turns lyrics on and off from the player. Dimmed while on but the song has none.
private struct LyricsToggle: View {
    let feature: LyricsFeature
    @State private var isHovered = false

    var body: some View {
        let isOn = feature.isEnabled
        let found = feature.lyrics != nil
        Button {
            feature.setEnabled(!isOn)
        } label: {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? (found ? Color.pink : .white.opacity(0.45)) : .white.opacity(0.6))
                .frame(width: 26, height: 32)
                .background(Circle().fill(.white.opacity(isHovered ? 0.12 : 0)).frame(width: 26, height: 26))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help(isOn: isOn, found: found))
        .accessibilityLabel(Text("Lyrics"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }

    private func help(isOn: Bool, found: Bool) -> String {
        guard isOn else { return "Show synced lyrics (looks the song up on lrclib.net)" }
        return switch feature.status {
        case .loading: "Looking for lyrics…"
        case .unavailable: "No synced lyrics for this song"
        default: found ? "Hide lyrics" : "Lyrics are on"
        }
    }
}
