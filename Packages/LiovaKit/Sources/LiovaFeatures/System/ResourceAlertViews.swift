import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// The heavy-app alert: the app's icon and its reading in the closed notch, so which app it
/// is shows without hovering; in the open notch, what it's doing to the Mac, and Quit. When
/// several apps add up, the flame and their total, and in the open notch each one.
@MainActor
public final class ResourceAlertRenderer: ActivityRenderer {
    private let feature: ResourceAlertFeature

    public init(feature: ResourceAlertFeature) {
        self.feature = feature
    }

    public func compactLeading(for activity: Activity) -> AnyView? {
        guard let alert = feature.alert, alert.crowd.isEmpty else {
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
        guard let alert = feature.alert else { return nil }
        return alert.crowd.isEmpty ? AnyView(ResourceAlertCard(feature: feature)) : AnyView(CrowdCard(feature: feature))
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
                if alert.app.canQuit {
                    actions
                } else {
                    ignoreButton
                }
            }
            .animation(Motion.list, value: feature.quitState)
        }
    }

    @ViewBuilder private var actions: some View {
        if feature.quitState == .running {
            ignoreButton
        }
        QuitButton(state: feature.quitState) {
            feature.quit()
        } forceQuit: {
            feature.forceQuit()
        }
    }

    private var ignoreButton: some View {
        IgnoreButton(help: "Don't mention this again until Liova restarts") { feature.ignore() }
    }
}

/// Several apps adding up: what each is using, busiest first, with Quit for the ones that
/// can be quit.
private struct CrowdCard: View {
    let feature: ResourceAlertFeature

    var body: some View {
        if let alert = feature.alert {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LoadLevel.busy.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(summary(alert))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    IgnoreButton(help: "Don't mention this again until Liova restarts") { feature.ignore() }
                }
                ForEach(alert.crowd) { app in
                    CrowdRow(app: app) { feature.quit(app) }
                }
            }
            .animation(Motion.list, value: alert.crowd.map(\.id))
        }
    }

    /// "Together 168% CPU, draining battery".
    private func summary(_ alert: ResourceAlert) -> String {
        let effect = alert.hot ? "your Mac is getting warm" : alert.onBattery ? "draining battery" : "warming your Mac"
        return "Together \(alert.reading) CPU, \(effect)"
    }
}

private struct CrowdRow: View {
    let app: AppUsage
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppUsageText.icon(for: app))
                .resizable()
                .frame(width: 16, height: 16)
            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            if let work = app.work {
                Text(work.activity)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(AppUsageText.cpu(app.cpu))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LoadLevel(app.cpu, on: .app).color)
            if app.canQuit {
                Button("Quit", action: quit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 34, alignment: .trailing)
            } else {
                Text("macOS")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 34, alignment: .trailing)
                    .help("Part of macOS. It stops on its own when it's done.")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IgnoreButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button("Ignore", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .help(help)
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
