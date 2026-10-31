import LiovaProviders
import SwiftUI

/// The System page: CPU, memory and GPU, each a large reading over a minute of history.
///
/// Colour carries meaning, not identity: calm is green, busy amber, maxed red, the same scale
/// as the volume HUD. Three columns split by hairlines, no boxes, so it sits in the black notch.
public struct SystemPage: View {
    let feature: SystemMonitorFeature

    public init(feature: SystemMonitorFeature) {
        self.feature = feature
    }

    public var body: some View {
        let history = feature.history
        let showsGPU = history.last?.gpu != nil || history.isEmpty
        HStack(spacing: 0) {
            Metric(title: "CPU", detail: Self.coreCount, scale: .load, values: history.map(\.cpu))
            separator
            Metric(
                title: "Memory", detail: Self.memoryDetail(history.last?.memory), scale: .memory,
                values: history.map(\.memory)
            )
            if showsGPU {
                separator
                Metric(title: "GPU", detail: nil, scale: .load, values: history.map { $0.gpu ?? 0 })
            }
        }
        .padding(.top, 2)
        .onAppear { feature.viewerAppeared() }
        .onDisappear { feature.viewerLeft() }
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 2)
            .padding(.horizontal, 14)
    }

    private static let coreCount = "\(ProcessInfo.processInfo.activeProcessorCount) cores"

    private static let totalMemory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    /// `10.2 / 16 GB`: what's in use of what's installed.
    static func memoryDetail(_ fraction: Double?) -> String {
        let total = totalMemory.rounded()
        guard let fraction else { return "\(Int(total)) GB" }
        return String(format: "%.1f / %.0f GB", fraction * totalMemory, total)
    }
}

/// How loaded something is, as a colour: calm, busy or maxed.
enum LoadLevel {
    case calm, busy, maxed

    /// Where busy and maxed start. Memory runs fuller than processors by design (macOS keeps
    /// it in use), so 65% memory is calm while 65% CPU is busy.
    struct Scale {
        var busy: Double
        var maxed: Double

        static let load = Scale(busy: 0.6, maxed: 0.85)
        static let memory = Scale(busy: 0.8, maxed: 0.92)
    }

    init(_ value: Double, on scale: Scale) {
        self = value >= scale.maxed ? .maxed : value >= scale.busy ? .busy : .calm
    }

    var color: Color {
        switch self {
        case .calm: Color(red: 0.19, green: 0.78, blue: 0.35)
        case .busy: Color(red: 1, green: 0.62, blue: 0.04)
        case .maxed: Color(red: 1, green: 0.27, blue: 0.23)
        }
    }
}

private struct Metric: View {
    let title: String
    let detail: String?
    let scale: LoadLevel.Scale
    let values: [Double]

    var body: some View {
        let current = values.last
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(current.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Circle()
                    .fill(LoadLevel(current ?? 0, on: scale).color)
                    .frame(width: 5, height: 5)
                    .padding(.leading, 5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 7 }
                    .opacity(current == nil ? 0 : 1)
            }
            LoadHistory(values: values, scale: scale)
                .frame(height: 24)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: current)
    }
}

/// A minute of readings as thin bars, newest on the right, older ones fading. Drawn in one
/// pass with Canvas; redraws once a second at most, and only while the page is open.
struct LoadHistory: View {
    let values: [Double]
    let scale: LoadLevel.Scale

    var body: some View {
        Canvas { context, size in
            for bar in Self.bars(values, in: size) {
                context.fill(
                    Path(roundedRect: bar.rect, cornerRadius: min(bar.rect.width, bar.rect.height) / 2),
                    with: .color(LoadLevel(bar.value, on: scale).color.opacity(bar.opacity))
                )
            }
        }
        .accessibilityHidden(true)
    }

    struct Bar: Equatable {
        var rect: CGRect
        var value: Double
        var opacity: Double
    }

    /// One slot per sample in the history; empty slots on the left until it fills. Each bar
    /// is at least a dot tall, so a quiet minute still reads as a line.
    static func bars(_ values: [Double], in size: CGSize) -> [Bar] {
        let slots = SystemMonitorFeature.historyLength
        let gap: CGFloat = 1
        let width = max((size.width - gap * CGFloat(slots - 1)) / CGFloat(slots), 0.5)
        let offset = slots - values.count
        return values.enumerated().map { index, value in
            let slot = offset + index
            let height = max(size.height * CGFloat(min(max(value, 0), 1)), width)
            let age = Double(values.count - 1 - index) / Double(slots)
            return Bar(
                rect: CGRect(x: CGFloat(slot) * (width + gap), y: size.height - height, width: width, height: height),
                value: value,
                opacity: 1 - age * 0.65
            )
        }
    }
}
