import LiovaPluginKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// The "new version" moment: an arrow in the closed notch, and in the open notch a card to
/// install it right there or read what's new.
@MainActor
public final class UpdateRenderer: ActivityRenderer {
    private let feature: UpdateFeature
    private let showDetails: @MainActor () -> Void

    public init(feature: UpdateFeature, showDetails: @escaping @MainActor () -> Void) {
        self.feature = feature
        self.showDetails = showDetails
    }

    public func compactLeading(for _: Activity) -> AnyView? {
        AnyView(
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.blue)
        )
    }

    public func compactTrailing(for _: Activity) -> AnyView? {
        guard let release = feature.availableRelease else { return nil }
        return AnyView(
            Text(release.version.description)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize()
        )
    }

    public func expanded(for _: Activity) -> AnyView? {
        guard feature.availableRelease != nil else { return nil }
        return AnyView(UpdateCard(feature: feature, showDetails: showDetails))
    }
}

private struct UpdateCard: View {
    let feature: UpdateFeature
    let showDetails: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white, .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Button("What's new") { showDetails() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            if feature.status.isBusy {
                progress
            } else {
                updateButton
            }
        }
    }

    private var title: String {
        let version = feature.availableRelease?.version.description ?? ""
        return switch feature.status {
        case .downloading: "Downloading Liova \(version)…"
        case .preparing: "Checking Liova \(version)…"
        case .installing: "Restarting with \(version)…"
        default: "Liova \(version) is available"
        }
    }

    @ViewBuilder private var progress: some View {
        if case let .downloading(_, fraction) = feature.status {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.blue)
                .frame(width: 90)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var updateButton: some View {
        Button {
            if feature.inPlaceSupport != .supported {
                // The installer opens in Finder; Settings says what to do with it.
                showDetails()
            }
            feature.install()
        } label: {
            Text(feature.inPlaceSupport == .supported ? "Update" : "Download")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(.blue, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
