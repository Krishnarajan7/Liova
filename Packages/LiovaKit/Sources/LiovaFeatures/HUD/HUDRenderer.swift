import LiovaPluginKit
import LiovaUI
import SwiftUI

/// Draws the volume/brightness HUD in the closed notch: the symbol on the left and a
/// level bar on the right, like the system HUD but in the notch.
@MainActor
public final class HUDRenderer: ActivityRenderer {
    public init() {}

    public func compactLeading(for activity: Activity) -> AnyView? {
        AnyView(
            Image(systemName: activity.symbol ?? "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(activity.tint == .yellow ? Color.yellow : Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
        )
    }

    public func compactTrailing(for activity: Activity) -> AnyView? {
        AnyView(LevelBar(level: activity.progress ?? 0, tint: activity.tint == .yellow ? .yellow : .white))
    }
}

/// A short horizontal level bar. Level changes are instant (key repeat fires every
/// ~80 ms, and an animation per press would lag behind the key).
private struct LevelBar: View {
    let level: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(tint).frame(width: max(0, proxy.size.width * level))
            }
        }
        .frame(width: 30, height: 5)
        .transaction { $0.animation = nil }
    }
}
