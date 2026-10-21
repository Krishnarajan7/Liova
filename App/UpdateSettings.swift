import LiovaCore
import LiovaFeatures
import LiovaProviders
import SwiftUI

/// Settings > Updates: what's installed, what's new, and how Liova looks for updates.
struct UpdateSettings: View {
    @Bindable var settings: LiovaSettings
    let updates: UpdateFeature

    var body: some View {
        Form {
            Section {
                StatusRow(updates: updates, lastCheck: settings.lastUpdateCheck)
                if let release = updates.availableRelease, !release.notes.isEmpty {
                    ReleaseNotes(markdown: release.notes)
                }
            } footer: {
                if let note = installNote {
                    Text(note)
                }
            }
            Section {
                Toggle("Check for updates automatically", isOn: $settings.automaticUpdateChecks)
                Toggle("Include beta versions", isOn: $settings.betaUpdates)
            } footer: {
                Text(
                    "Once a day Liova asks GitHub for its latest release. The request carries only Liova's "
                        + "version; nothing about you or your Mac. Updates install only when they're signed by "
                        + "the same developer as this copy."
                )
            }
        }
        .formStyle(.grouped)
    }

    /// Why this copy can't replace itself, when it can't.
    private var installNote: String? {
        switch updates.inPlaceSupport {
        case .supported: nil
        case .adHocBuild:
            "This copy isn't signed with Liova's release certificate (built from source, for example), so "
                + "updates download and open in Finder for you to install."
        case .translocated:
            "Move Liova to the Applications folder so it can update itself. Until then, updates open in Finder."
        case .notWritable:
            "Liova can't write to the folder it's in, so updates open in Finder for you to install."
        }
    }
}

private struct StatusRow: View {
    let updates: UpdateFeature
    let lastCheck: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.headline)
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
    }

    private var headline: String {
        switch updates.status {
        case .idle, .checking, .upToDate:
            "Liova \(updates.currentVersion?.description ?? Bundle.main.shortVersion)"
        case let .available(release), let .failed(release?, _):
            "Liova \(release.version) is available"
        case let .downloading(release, _), let .preparing(release):
            "Updating to \(release.version)"
        case let .installing(release):
            "Restarting with \(release.version)…"
        case let .openedInstaller(release):
            "Liova \(release.version) is ready to install"
        case .failed(nil, _):
            "Couldn't check for updates"
        }
    }

    @ViewBuilder private var detail: some View {
        switch updates.status {
        case .idle, .upToDate:
            if let lastCheck {
                Text("Up to date · checked \(lastCheck, format: .relative(presentation: .named))")
            } else {
                Text("Not checked yet")
            }
        case .checking:
            Text("Checking…")
        case let .available(release):
            Text("You have \(updates.currentVersion?.description ?? "an older version")" + published(release))
        case let .downloading(_, progress):
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 160)
        case .preparing:
            Text("Checking the download and its signature…")
        case .installing:
            Text("Liova will reopen in a moment.")
        case .openedInstaller:
            Text("Drag Liova into Applications to replace this copy, then open it.")
        case let .failed(_, message):
            Text(message).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var actions: some View {
        switch updates.status {
        case .available, .failed(.some, _):
            HStack(spacing: 8) {
                Button("Skip") { updates.skip() }
                Button(updates.inPlaceSupport == .supported ? "Install and Relaunch" : "Download") {
                    updates.install()
                }
                .keyboardShortcut(.defaultAction)
            }
        case .checking, .downloading, .preparing, .installing:
            ProgressView().controlSize(.small)
        case .idle, .upToDate, .failed(nil, _), .openedInstaller:
            Button("Check Now") { updates.checkNow() }
        }
    }

    private func published(_ release: ReleaseInfo) -> String {
        guard let date = release.publishedAt else { return "" }
        return " · released \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// A release's notes: headings bold, list items with bullets, inline Markdown kept.
private struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    line
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
    }

    private var lines: [Text] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                return Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).bold()
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var item = AttributedString("•  ")
                item += inline(String(line.dropFirst(2)))
                return Text(item)
            }
            return Text(inline(line))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
