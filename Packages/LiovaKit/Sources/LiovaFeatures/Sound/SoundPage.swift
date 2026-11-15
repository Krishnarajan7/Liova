import LiovaProviders
import LiovaUI
import SwiftUI

/// The Sound page: outputs on the left, inputs on the right, the one in use marked.
/// Click another to switch to it.
public struct SoundPage: View {
    let feature: SoundFeature

    public init(feature: SoundFeature) {
        self.feature = feature
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DeviceList(
                title: "Output", empty: "No speakers", devices: feature.devices.outputs,
                current: feature.devices.currentOutput, isInput: false
            ) { feature.useOutput($0) }
            DeviceList(
                title: "Input", empty: "No microphone", devices: feature.devices.inputs,
                current: feature.devices.currentInput, isInput: true
            ) { feature.useInput($0) }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { feature.pageAppeared() }
        .onDisappear { feature.pageDisappeared() }
    }
}

private struct DeviceList: View {
    let title: String
    let empty: String
    let devices: [AudioDevice]
    let current: String?
    let isInput: Bool
    let choose: (AudioDevice) -> Void

    /// More than this many scroll, so a Mac with a dozen devices doesn't fill the screen.
    private static let visibleRows = 4
    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 8)
            if devices.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(height: Self.rowHeight)
                    .padding(.leading, 8)
            } else if devices.count > Self.visibleRows {
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .frame(height: CGFloat(Self.visibleRows) * (Self.rowHeight + 2))
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(devices) { device in
                DeviceRow(device: device, isCurrent: device.id == current, isInput: isInput) { choose(device) }
                    .frame(height: Self.rowHeight)
                    .transition(Motion.listItem)
            }
        }
        .animation(Motion.list, value: devices.map(\.id))
    }
}

private struct DeviceRow: View {
    let device: AudioDevice
    let isCurrent: Bool
    let isInput: Bool
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: SoundPolicy.symbol(for: device.kind, isInput: isInput))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                Text(device.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .foregroundStyle(.white.opacity(isCurrent ? 1 : isHovered ? 0.9 : 0.65))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isCurrent ? 0.14 : isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isCurrent)
        .help(isCurrent ? "\(device.name) is in use" : "Use \(device.name)")
        .accessibilityLabel(Text(device.name))
        .accessibilityValue(Text(isCurrent ? "In use" : ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
