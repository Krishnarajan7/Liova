import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// Draws download activities: an arrow and a progress ring (or the speed) when closed,
/// and a card with name, app, bar, size, speed and time left when open.
///
/// Everything is static between updates: no looping animation, and streamed values are
/// written without animation (performance rules 3 and 6).
@MainActor
public final class DownloadsRenderer: ActivityRenderer {
    private let feature: DownloadsFeature

    public init(feature: DownloadsFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        AnyView(
            Image(systemName: activity.symbol ?? DownloadsPolicy.activeSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.color(for: activity))
                .frame(width: 21, height: 21)
        )
    }

    public func compactTrailing(for activity: Activity) -> AnyView? {
        guard activity.id != DownloadsPolicy.finishedID else { return nil }
        if let progress = activity.progress {
            return AnyView(DownloadRing(progress: progress).frame(width: 16, height: 16))
        }
        return AnyView(CompactRate(feature: feature, activityID: activity.id))
    }

    public func expanded(for activity: Activity) -> AnyView? {
        if activity.id == DownloadsPolicy.combinedID {
            return AnyView(CombinedCard(feature: feature, activity: activity))
        }
        guard feature.item(for: activity.id) != nil else { return nil }
        return AnyView(DownloadCard(feature: feature, activityID: activity.id))
    }

    static func color(for activity: Activity) -> Color {
        activity.tint == .green ? .green : .blue
    }
}

/// The speed in compact form (`8.3M/s`) when the total isn't known.
private struct CompactRate: View {
    let feature: DownloadsFeature
    let activityID: ActivityID

    var body: some View {
        let items = activityID == DownloadsPolicy.combinedID ? feature.items : feature.item(for: activityID)
            .map { [$0] }
            ?? []
        let rates = items.compactMap(\.throughput)
        Group {
            if rates.isEmpty {
                Text(DownloadsFormat.compactBytes(items.reduce(0) { $0 + $1.bytesCompleted }))
            } else {
                Text(DownloadsFormat.compactSpeed(rates.reduce(0, +)))
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.blue)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .transaction { $0.animation = nil }
    }
}

private struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.blue.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .transaction { $0.animation = nil }
    }
}

/// A determinate bar, or, with no total, a plain full-width track (static, never animated).
private struct DownloadBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(fraction == nil ? 0.22 : 0.12))
                if let fraction {
                    Capsule().fill(Color.blue).frame(width: max(4, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: 5)
        .transaction { $0.animation = nil }
    }
}

private struct DownloadCard: View {
    let feature: DownloadsFeature
    let activityID: ActivityID

    var body: some View {
        if let item = feature.item(for: activityID) {
            HStack(spacing: 12) {
                Image(systemName: DownloadsPolicy.activeSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let app = item.sourceApp {
                            Text(app)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    DownloadBar(fraction: item.fractionCompleted)
                        .padding(.vertical, 3)
                    DownloadStats(item: item)
                }
            }
        }
    }
}

private struct DownloadStats: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 0) {
            Text(sizeText)
            Spacer(minLength: 8)
            Text(trailingText)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(1)
        .transaction { $0.animation = nil }
    }

    private var sizeText: String {
        guard let total = item.totalBytes else { return DownloadsFormat.bytes(item.bytesCompleted) }
        return "\(DownloadsFormat.bytes(item.bytesCompleted)) of \(DownloadsFormat.bytes(total))"
    }

    private var trailingText: String {
        var parts: [String] = []
        if let rate = item.throughput {
            parts.append(DownloadsFormat.speed(rate))
        }
        if item.totalBytes != nil, let remaining = item.estimatedTimeRemaining,
           let text = DownloadsFormat.timeRemaining(remaining)
        {
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }
}

/// More downloads than fit as separate activities: totals, then a row per download.
private struct CombinedCard: View {
    let feature: DownloadsFeature
    let activity: Activity
    private static let maxRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: DownloadsPolicy.activeSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(activity.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if let subtitle = activity.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            ForEach(feature.items.prefix(Self.maxRows)) { item in
                HStack(spacing: 8) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DownloadBar(fraction: item.fractionCompleted)
                        .frame(width: 90)
                }
            }
        }
        .transaction { $0.animation = nil }
    }
}
