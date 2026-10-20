import SwiftUI

/// Liova's license and those of what ships inside it, read from the app bundle, where the
/// build copies the original files (see project.yml).
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Notice: Identifiable {
        let id: String
        let title: String
        let detail: String
        var text = ""
    }

    /// Each folder under `Resources/Licenses`, with what it is.
    private static let entries = [
        Notice(id: "Liova", title: "Liova", detail: "MIT License"),
        Notice(
            id: "mediaremote-adapter",
            title: "mediaremote-adapter",
            detail: "Now Playing on modern macOS. BSD 3-Clause License"
        ),
    ]

    private let notices: [Notice] = entries.compactMap { entry in
        guard let url = Bundle.main.url(
            forResource: "LICENSE",
            withExtension: nil,
            subdirectory: "Licenses/\(entry.id)"
        ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        var notice = entry
        notice.text = text
        return notice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Licenses").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(notices) { notice in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(notice.title).font(.headline)
                            Text(notice.detail).font(.caption).foregroundStyle(.secondary)
                            Text(notice.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    Text(
                        "Synced lyrics, when turned on, come from LRCLIB (lrclib.net), a free community database. "
                            + "Lyrics belong to their rights holders. Weather, when turned on, is by Open-Meteo.com "
                            + "(CC BY 4.0). \"Dynamic Island\", \"AirPods\" and \"EarPods\" "
                            + "are trademarks of Apple Inc.; Liova is not affiliated with Apple."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}
