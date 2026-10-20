import LiovaProviders
import SwiftUI

/// Battery level beside the camera in the open notch: always there, green with a bolt while
/// charging, red when low. Reads the battery feature's store, so it updates only when the
/// battery actually changes.
public struct BatteryStatusView: View {
    let feature: BatteryFeature
    let detail: Detail

    /// How much to show, for when the header is crowded. What's dropped stays in the tooltip.
    public enum Detail: Sendable {
        /// Bolt, percentage and battery.
        case full
        /// Percentage and battery; green alone says charging.
        case percentage
        /// The battery alone.
        case icon
    }

    public init(feature: BatteryFeature, detail: Detail = .full) {
        self.feature = feature
        self.detail = detail
    }

    public var body: some View {
        if let snapshot = feature.snapshot, snapshot.hasBattery {
            let charging = snapshot.isPluggedIn
            let color: Color = charging ? .green : snapshot.percentage <= 20 ? .red : .white.opacity(0.85)
            HStack(spacing: 4) {
                if charging, detail == .full {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                if detail != .icon {
                    Text("\(snapshot.percentage)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .contentTransition(.numericText(value: Double(snapshot.percentage)))
                        .lineLimit(1)
                }
                MiniBattery(level: Double(snapshot.percentage) / 100, color: color)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: charging)
            .animation(.easeOut(duration: 0.3), value: snapshot.percentage)
            .fixedSize()
            .help("\(snapshot.percentage)%, \(charging ? "charging" : "on battery")")
        }
    }
}

private struct MiniBattery: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(spacing: 0.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(color)
                    .frame(width: max(1.5, 15 * level))
                    .padding(1.5)
            }
            .frame(width: 19, height: 9.5)
            RoundedRectangle(cornerRadius: 0.5)
                .fill(.white.opacity(0.4))
                .frame(width: 1.2, height: 3.5)
        }
    }
}
