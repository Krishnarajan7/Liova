import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// The headphones moment in the closed notch: their icon on the left, the battery of the
/// bud that runs out first on the right.
///
/// Arriving, the icon drops in and a blue light sweeps left to right; leaving, a slash
/// strikes through it as it dims and the light sweeps back right to left, like the
/// charging moment. One-shot, so the closed notch never loops.
@MainActor
public final class HeadphonesRenderer: ActivityRenderer {
    private let feature: HeadphonesFeature

    public init(feature: HeadphonesFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        AnyView(HeadphonesGlyph(
            symbol: activity.symbol ?? "headphones",
            isLeaving: activity.id == HeadphonesPolicy.disconnectedID
        ))
    }

    public func compactTrailing(for activity: Activity) -> AnyView? {
        guard activity.id != HeadphonesPolicy.disconnectedID,
              let device = device(for: activity), let level = device.battery.lowest
        else { return nil }
        return AnyView(BatteryBadge(level: level))
    }

    public func compactBackground(for activity: Activity) -> AnyView? {
        switch activity.id {
        case HeadphonesPolicy.connectedID: AnyView(EnergySweep(color: .blue, reversed: false))
        case HeadphonesPolicy.disconnectedID: AnyView(EnergySweep(color: .white.opacity(0.6), reversed: true))
        default: nil
        }
    }

    public func expanded(for activity: Activity) -> AnyView? {
        if activity.id == HeadphonesPolicy.disconnectedID {
            guard let device = feature.lastDisconnected else { return nil }
            return AnyView(DisconnectedCard(device: device))
        }
        guard let device = device(for: activity) else { return nil }
        return AnyView(HeadphonesCard(feature: feature, deviceID: device.id))
    }

    private func device(for activity: Activity) -> HeadphonesState? {
        let id = feature.deviceIDByActivity[activity.id]
        return feature.devices.first { $0.id == id }
    }
}

/// The headphones icon in the closed notch. Drops in on arrival; on departure a slash
/// strikes through it as it dims.
private struct HeadphonesGlyph: View {
    let symbol: String
    let isLeaving: Bool
    @State private var arrived = false
    @State private var slash: CGFloat = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .opacity(isLeaving ? 1 - 0.6 * slash : (arrived ? 1 : 0))
            .scaleEffect(isLeaving ? 1 - 0.1 * slash : (arrived ? 1 : 0.5))
            .offset(y: isLeaving || arrived ? 0 : -7)
            .overlay {
                if isLeaving {
                    SlashLine()
                        .trim(from: 0, to: slash)
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .shadow(color: .black, radius: 0.5)
                        .padding(-1)
                }
            }
            .onAppear {
                if isLeaving {
                    withAnimation(.easeInOut(duration: 0.4).delay(0.2)) { slash = 1 }
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.1)) { arrived = true }
                }
            }
    }
}

/// Top-left to bottom-right, like SF Symbols' slashes.
private struct SlashLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }
}

/// The open notch's view of headphones that just went away.
private struct DisconnectedCard: View {
    let device: HeadphonesState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.05)))
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text("Disconnected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
    }
}

/// Beside the battery in the open notch while headphones are connected. Opens the
/// headphones page.
public struct HeadphonesStatusView: View {
    let feature: HeadphonesFeature
    /// Icon only, for when the header is crowded.
    let isCompact: Bool
    @Environment(\.openNotchPage) private var openPage

    public init(feature: HeadphonesFeature, isCompact: Bool = false) {
        self.feature = feature
        self.isCompact = isCompact
    }

    public var body: some View {
        if let device = feature.devices.first {
            Button {
                feature.refresh()
                openPage(HeadphonesPolicy.pageID)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: device.kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                    if !isCompact, let level = device.battery.lowest {
                        Text("\(level)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                .foregroundStyle(HeadphonesPolicy.isLow(device.battery) ? .red : .white.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(accessibilityText(device))
            .accessibilityLabel(Text(accessibilityText(device)))
            .onAppear { feature.refresh() }
        }
    }

    private func accessibilityText(_ device: HeadphonesState) -> String {
        [device.name, HeadphonesPolicy.batterySummary(device.battery)].compactMap(\.self).joined(separator: ", ")
    }
}

/// The headphones page: every connected pair with its battery and noise control.
public struct HeadphonesPage: View {
    let feature: HeadphonesFeature

    public init(feature: HeadphonesFeature) {
        self.feature = feature
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(feature.devices.prefix(2)) { device in
                HeadphonesCard(feature: feature, deviceID: device.id)
            }
            Spacer(minLength: 0)
        }
        .onAppear { feature.refresh() }
    }
}

/// One pair: name and icon, a gauge per bud and the case, and noise-control buttons.
struct HeadphonesCard: View {
    let feature: HeadphonesFeature
    let deviceID: String

    var body: some View {
        if let device = feature.devices.first(where: { $0.id == deviceID }) {
            HStack(spacing: 14) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if device.isWired {
                        Text("Wired")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    } else {
                        BatteryRow(battery: device.battery)
                    }
                }
                Spacer(minLength: 8)
                if !device.availableModes.isEmpty {
                    ModePicker(device: device) { feature.setListeningMode($0, for: device.id) }
                }
            }
        }
    }
}

private struct BatteryRow: View {
    let battery: HeadphonesState.Battery

    var body: some View {
        HStack(spacing: 12) {
            if battery.isEmpty {
                Text("Battery not reported yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let left = battery.left {
                Gauge(label: "L", level: left)
            }
            if let right = battery.right {
                Gauge(label: "R", level: right)
            }
            if let single = battery.single, battery.left == nil, battery.right == nil {
                Gauge(label: nil, level: single)
            }
            if let caseLevel = battery.caseLevel {
                Gauge(label: "Case", level: caseLevel)
            }
        }
    }
}

private struct Gauge: View {
    let label: String?
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            BatteryBadge(level: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label.map { "\($0) " } ?? "")\(level) percent"))
    }
}

/// A small ring and percentage, red at or below the warning level.
struct BatteryBadge: View {
    let level: Int

    var body: some View {
        let color: Color = level <= HeadphonesPolicy.warningLevel ? .red : .green
        HStack(spacing: 3) {
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: Double(level) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text("\(level)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
        .transaction { $0.animation = nil }
    }
}

/// Off, Noise Cancellation, Transparency (and Adaptive when the headphones are in it).
private struct ModePicker: View {
    let device: HeadphonesState
    let select: (HeadphonesState.ListeningMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(device.availableModes, id: \.self) { mode in
                ModeButton(mode: mode, isSelected: device.listeningMode == mode) { select(mode) }
            }
        }
    }
}

private struct ModeButton: View {
    let mode: HeadphonesState.ListeningMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.white : .white.opacity(isHovered ? 0.16 : 0.08))
                    )
                    .foregroundStyle(isSelected ? Color.black : .white)
                Text(mode.shortTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSelected)
        .help(mode.title)
        .accessibilityLabel(Text(mode.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
