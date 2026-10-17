import LiovaCore
import LiovaPluginKit
import SwiftUI

/// The open notch. Shows the visible activity in detail and the rest of the stack below it.
struct ExpandedView: View {
    let engine: ActivityEngine
    let renderers: ActivityRendererRegistry
    let cameraHeight: CGFloat

    private static let maxQueued = 2
    /// Activities ending within this window are "brief" (a charging flash, a HUD, a finished
    /// agent turn). In the open notch they appear as a chip beside the camera instead of
    /// taking over the main card, so what you opened the notch for stays put.
    static let briefWindow: TimeInterval = 15

    static func isBrief(_ activity: Activity, now: Date) -> Bool {
        guard let expiresAt = activity.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= briefWindow
    }

    var body: some View {
        let now = Date()
        let lasting = engine.activities.filter { !Self.isBrief($0, now: now) }
        let brief = engine.activities.first { Self.isBrief($0, now: now) }

        VStack(alignment: .leading, spacing: 10) {
            // Keep the camera housing clear; brief events sit to its right.
            HStack {
                Spacer(minLength: 0)
                if let brief {
                    BriefChip(activity: brief)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
            }
            .frame(height: max(cameraHeight - 6, 0))
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: brief?.id)

            if let current = lasting.first ?? brief {
                let renderer = renderers.renderer(for: current)
                if let custom = renderer?.expanded(for: current) {
                    custom
                } else {
                    ActivityCard(activity: current)
                }
                let showsQueue = !(renderer?.expandedNeedsFullHeight(for: current) ?? false)
                let queued = showsQueue ? lasting.dropFirst().prefix(Self.maxQueued) : []
                if !queued.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(queued) { ActivityRow(activity: $0) }
                    }
                }
                Spacer(minLength: 0)
            } else {
                EmptyState()
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A brief event, shown small beside the camera while the notch is open.
private struct BriefChip: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 5) {
            ActivitySymbol(activity: activity, size: 11)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(activity.tint.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(activity.tint.color.opacity(0.14), in: Capsule())
        .frame(maxWidth: 120, alignment: .trailing)
    }

    private var label: String {
        if let progress = activity.progress {
            return "\(Int((progress * 100).rounded()))%"
        }
        return activity.subtitle ?? activity.title
    }
}

private struct ActivityCard: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 12) {
            ActivitySymbol(activity: activity, size: 22)
                .frame(width: 40, height: 40)
                .background(activity.tint.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = activity.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if let progress = activity.progress {
                    ProgressBar(progress: progress, tint: activity.tint.color)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            if let progress = activity.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 8) {
            ActivitySymbol(activity: activity, size: 11)
            Text(activity.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let progress = activity.progress {
                ProgressBar(progress: progress, tint: activity.tint.color)
                    .frame(width: 60)
            }
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing live right now")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Activities from your Mac, apps and agents appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
