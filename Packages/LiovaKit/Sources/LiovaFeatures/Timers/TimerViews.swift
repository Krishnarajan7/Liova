import LiovaPluginKit
import LiovaUI
import SwiftUI

/// Draws timers: a countdown in the closed notch, controls when open.
///
/// The countdown uses SwiftUI's timer text, which the system redraws once a second on its
/// own; Liova does no per-second work.
@MainActor
public final class TimerRenderer: ActivityRenderer {
    private let feature: TimerFeature

    public init(feature: TimerFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        AnyView(
            Image(systemName: activity.symbol ?? "timer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .contentTransition(.symbolEffect(.replace))
        )
    }

    public func compactTrailing(for activity: Activity) -> AnyView? {
        guard let id = TimerPolicy.timerID(from: activity.id), let timer = feature.timer(id) else { return nil }
        return AnyView(Countdown(timer: timer, size: 12.5))
    }

    public func expanded(for activity: Activity) -> AnyView? {
        guard let id = TimerPolicy.timerID(from: activity.id), let timer = feature.timer(id) else { return nil }
        return AnyView(TimerCard(timer: timer, feature: feature))
    }
}

/// Remaining time, counting down live while running and frozen while paused.
private struct Countdown: View {
    let timer: NotchTimer
    let size: CGFloat

    var body: some View {
        Group {
            if let endDate = timer.endDate, endDate > .now {
                Text(timerInterval: Date.now ... endDate, countsDown: true)
            } else {
                Text(TimerPolicy.format(timer.remaining(at: .now)))
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(timer.isPaused ? .white.opacity(0.5) : .orange)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct TimerCard: View {
    let timer: NotchTimer
    let feature: TimerFeature

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.orange.opacity(0.2), lineWidth: 4)
                if let endDate = timer.endDate, endDate > .now {
                    ProgressView(
                        timerInterval: endDate.addingTimeInterval(-timer.duration) ... endDate,
                        countsDown: true
                    ) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(RingStyle())
                } else {
                    RingStyle.Ring(fraction: timer.duration > 0 ? timer.remaining(at: .now) / timer.duration : 0)
                }
                Image(systemName: timer.isPaused ? "pause.fill" : "timer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Countdown(timer: timer, size: 26)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                TimerButton(symbol: "plus", label: "1 min") {
                    withAnimation(Motion.list) { feature.extend(timer.id, by: 60) }
                }
                TimerButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", label: nil) {
                    withAnimation(Motion.list) {
                        if timer.isPaused {
                            feature.resume(timer.id)
                        } else {
                            feature.pause(timer.id)
                        }
                    }
                }
                TimerButton(symbol: "xmark", label: nil, tint: .red) {
                    withAnimation(Motion.list) { feature.cancel(timer.id) }
                }
            }
        }
    }
}

/// A ring that fills as time runs out; driven by the system's timer progress.
private struct RingStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        Ring(fraction: configuration.fractionCompleted ?? 0)
    }

    struct Ring: View {
        let fraction: Double

        var body: some View {
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct TimerButton: View {
    let symbol: String
    let label: String?
    var tint: Color = .white
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                if let label {
                    Text(label).font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, label == nil ? 0 : 10)
            .frame(minWidth: 30, minHeight: 30)
            .background(tint.opacity(isHovered ? 0.22 : 0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// The Timers page: presets, a custom length, and the timers already running.
public struct TimersPage: View {
    let feature: TimerFeature
    @State private var customMinutes = 15

    public init(feature: TimerFeature) {
        self.feature = feature
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(TimerFeature.presets, id: \.self) { preset in
                    PresetButton(title: "\(Int(preset / 60)) min") {
                        withAnimation(Motion.list) { _ = feature.start(duration: preset) }
                    }
                }
                Divider().frame(height: 22).overlay(.white.opacity(0.15))
                Stepper(value: $customMinutes, in: 1 ... 180) {
                    Text("\(customMinutes) min")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
                .controlSize(.small)
                PresetButton(title: "Start", prominent: true) {
                    withAnimation(Motion.list) { _ = feature.start(duration: TimeInterval(customMinutes * 60)) }
                }
            }
            .disabled(feature.timers.count >= TimerFeature.maxTimers)
            ZStack(alignment: .topLeading) {
                if feature.timers.isEmpty {
                    Text("Start a timer and it counts down in the notch, even while it's closed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .transition(.opacity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(feature.timers) { timer in
                                TimerRow(timer: timer, feature: feature)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
                                    ))
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(Motion.list, value: feature.timers.map(\.id))
        }
        .padding(.top, 4)
    }
}

private struct TimerRow: View {
    let timer: NotchTimer
    let feature: TimerFeature

    var body: some View {
        HStack {
            Image(systemName: timer.isPaused ? "pause.circle.fill" : "timer")
                .foregroundStyle(.orange)
                .contentTransition(.symbolEffect(.replace))
            Text(timer.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Countdown(timer: timer, size: 13)
            Button {
                withAnimation(Motion.list) { feature.cancel(timer.id) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PresetButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    prominent ? Color.orange.opacity(isHovered ? 1 : 0.9) : Color.white.opacity(isHovered ? 0.18 : 0.1),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
