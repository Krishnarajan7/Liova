import SwiftUI

public extension LyricsFeature {
    /// Why there are no lyrics to show, in words the notch can say.
    enum Missing: Equatable, Sendable {
        /// Looked up: the song has no words.
        case instrumental
        /// Looked up: there are lyrics, but not timed to the song.
        case unsynced
        /// Looked up: nothing for this song.
        case notFound
        /// The lookup couldn't reach lrclib.net. Not remembered, so the next play asks again.
        case offline
        /// Not looked up: a podcast.
        case podcast
        /// Not looked up: no length, or too short or long to be a song (a video, a mix).
        case notASong
        /// Not looked up: nothing to search by.
        case noArtist

        public var message: String {
            switch self {
            case .instrumental: "Instrumental, no lyrics"
            case .unsynced: "Lyrics found, but not timed to the song"
            case .notFound: "No lyrics found for this song"
            case .offline: "Couldn't look up lyrics. Offline?"
            case .podcast: "Podcasts don't have lyrics"
            case .notASong: "This doesn't look like a song"
            case .noArtist: "No artist, so no lyrics to look up"
            }
        }

        public var symbol: String {
            switch self {
            case .instrumental: "pianokeys"
            case .offline: "wifi.slash"
            default: "text.badge.xmark"
            }
        }

        /// Worth a brief word under the closed notch: a song that was looked up and came back
        /// empty. Videos and podcasts would say it every time, so they only show it when open.
        public var announces: Bool {
            switch self {
            case .instrumental, .unsynced, .notFound, .offline: true
            case .podcast, .notASong, .noArtist: false
            }
        }
    }
}

/// Why there are no lyrics, where they'd be.
struct MissingLyrics: View {
    let missing: LyricsFeature.Missing

    var body: some View {
        Label(missing.message, systemImage: missing.symbol)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .lineLimit(1)
    }
}

/// Turns lyrics on and off from the player. Dimmed while on but the song has none.
struct LyricsToggle: View {
    let feature: LyricsFeature
    @State private var isHovered = false

    var body: some View {
        let isOn = feature.isEnabled
        let found = feature.lyrics != nil
        Button {
            feature.setEnabled(!isOn)
        } label: {
            // On but nothing found for this song: marked on, without the colour.
            PlayerToggleGlyph(symbol: "quote.bubble", isOn: isOn, isLit: isOn && found, isHovered: isHovered)
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
        case let .unavailable(missing): missing.message
        default: found ? "Hide lyrics" : "Lyrics are on"
        }
    }
}
