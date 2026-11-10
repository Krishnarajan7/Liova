import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// The heavy-app alert: the app's icon and its reading in the closed notch, so which app it
/// is shows without hovering; in the open notch, what it's doing to the Mac, and Quit.
@MainActor
public final class ResourceAlertRenderer: ActivityRenderer {
    private let feature: ResourceAlertFeature

    public init(feature: ResourceAlertFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        guard let alert = feature.alert else {
            return AnyView(
                Image(systemName: activity.symbol ?? "flame.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LoadLevel.busy.color)
            )
        }
        return AnyView(
            Image(nsImage: AppUsageText.icon(for: alert.app))
                .resizable()
                .frame(width: 18, height: 18)
                .overlay(alignment: .bottomTrailing) {
                    ResourceBadge(reason: alert.reason, size: 6)
                        .offset(x: 3, y: 3)
                }
                .help(alert.title)
        )
    }

    public func compactTrailing(for _: Activity) -> AnyView? {
        guard let alert = feature.alert else { return nil }
        return AnyView(
            Text(alert.reading)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LoadLevel.busy.color)
                .lineLimit(1)
                .fixedSize()
        )
    }

    public func expanded(for _: Activity) -> AnyView? {
        guard feature.alert != nil else { return nil }
        return AnyView(ResourceAlertCard(feature: feature))
    }
}

private struct ResourceAlertCard: View {
    let feature: ResourceAlertFeature

    var body: some View {
        if let alert = feature.alert {
            HStack(spacing: 12) {
                Image(nsImage: AppUsageText.icon(for: alert.app))
                    .resizable()
                    .frame(width: 34, height: 34)
                    .overlay(alignment: .bottomTrailing) {
                        ResourceBadge(reason: alert.reason, size: 10)
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(alert.detail)
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if feature.quitState == .running {
                    Button("Ignore") { feature.ignore() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .help("Don't mention this app again until Liova restarts")
                }
                QuitButton(state: feature.quitState) {
                    feature.quit()
                } forceQuit: {
                    feature.forceQuit()
                }
            }
            .animation(Motion.list, value: feature.quitState)
        }
    }
}

/// Flame for a busy processor, chip for memory, on the app's icon.
private struct ResourceBadge: View {
    let reason: ResourceAlert.Reason
    let size: CGFloat

    var body: some View {
        Image(systemName: reason == .memory ? "memorychip.fill" : "flame.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(LoadLevel.busy.color)
            .padding(size * 0.3)
            .background(.black, in: Circle())
    }
}
