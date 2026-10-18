import Foundation
import LiovaCore
import LiovaPluginKit
import LiovaUI
import SwiftUI

/// The first-launch welcome: a short card in the open notch that teaches the three things
/// worth knowing, shown once.
@MainActor
public final class WelcomeFeature {
    public static let source = "system.welcome"
    public static let activityID: ActivityID = "system.welcome"
    static let duration: TimeInterval = 20

    private let engine: ActivityEngine
    private let settings: LiovaSettings

    public init(engine: ActivityEngine, settings: LiovaSettings) {
        self.engine = engine
        self.settings = settings
    }

    /// Shows the welcome if it hasn't been shown. Returns true when it did (the caller opens
    /// the notch so it's seen).
    @discardableResult
    public func showIfNeeded(now: Date = Date()) -> Bool {
        guard !settings.hasSeenWelcome else { return false }
        settings.hasSeenWelcome = true
        try? engine.start(Activity(
            id: Self.activityID, source: Self.source, priority: .high,
            title: "Welcome to Liova", subtitle: "Hover the notch to open it",
            symbol: "sparkles", tint: .purple, expiresAt: now + Self.duration
        ))
        return true
    }

    public func dismiss() {
        engine.end(Self.activityID)
    }
}

@MainActor
public final class WelcomeRenderer: ActivityRenderer {
    private let feature: WelcomeFeature
    private let openSettings: () -> Void

    public init(feature: WelcomeFeature, openSettings: @escaping () -> Void) {
        self.feature = feature
        self.openSettings = openSettings
    }

    public func expandedNeedsFullHeight(for _: Activity) -> Bool {
        true
    }

    public func expanded(for _: Activity) -> AnyView? {
        AnyView(WelcomeCard(dismiss: feature.dismiss, openSettings: openSettings))
    }
}

private struct WelcomeCard: View {
    let dismiss: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("Welcome to Liova")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Button("Got it", action: dismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(.white, in: Capsule())
            }
            Tip(
                symbol: "cursorarrow.motionlines",
                text: "Hover the notch to open it. Music, downloads and timers live here."
            )
            Tip(
                symbol: "tray.and.arrow.down.fill",
                text: "Drag files onto the notch to keep them on the Shelf or AirDrop them."
            )
            Tip(symbol: "terminal.fill", text: "Run `liova agents install claude-code` to see Claude Code here.")
        }
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 16)
            Text(.init(text))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}
