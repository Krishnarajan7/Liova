import LiovaProviders
import SwiftUI

/// The System page: CPU, memory and GPU load with a minute of history each.
public struct SystemPage: View {
    let feature: SystemMonitorFeature

    public init(feature: SystemMonitorFeature) {
        self.feature = feature
    }

    public var body: some View {
        let history = feature.history
        HStack(spacing: 10) {
            MetricCard(title: "CPU", symbol: "cpu", color: .cyan, values: history.map(\.cpu))
            MetricCard(title: "Memory", symbol: "memorychip", color: .green, values: history.map(\.memory))
            if history.last?.gpu != nil || history.isEmpty {
                MetricCard(
                    title: "GPU",
                    symbol: "square.stack.3d.up.fill",
                    color: .purple,
                    values: history.map { $0.gpu ?? 0 }
                )
            }
        }
        .padding(.top, 4)
        .onAppear { feature.viewerAppeared() }
        .onDisappear { feature.viewerLeft() }
    }
}

private struct MetricCard: View {
    let title: String
    let symbol: String
    let color: Color
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
                Text(values.last.map { String(format: "%.1f%%", $0 * 100) } ?? "–")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            Sparkline(values: values, color: color)
                .frame(height: 30)
        }
        .padding(9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: values.last)
    }
}

/// A line of recent values with a soft fill beneath. Redraws once a second at most.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = Self.points(values, in: proxy.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .shadow(color: color.opacity(0.6), radius: 3)
                } else {
                    Capsule().fill(color.opacity(0.2)).frame(height: 1.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        let slots = max(SystemMonitorFeature.historyLength - 1, 1)
        let offset = slots - (values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(
                x: size.width * CGFloat(offset + index) / CGFloat(slots),
                y: size.height * (1 - CGFloat(min(max(value, 0), 1)) * 0.92) - 1
            )
        }
    }
}
