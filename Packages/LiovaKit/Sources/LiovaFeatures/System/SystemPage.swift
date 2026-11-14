import AppKit
import LiovaProviders
import LiovaUI
import SwiftUI

/// The System page: CPU, memory and GPU, each a large reading over a minute of history, and
/// below them the apps using the most, each with a Quit button.
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
        VStack(spacing: 9) {
            metrics(history: history, showsGPU: showsGPU)
            AppList(feature: feature)
        }
        .padding(.top, 2)
        .onAppear { feature.viewerAppeared() }
        .onDisappear { feature.viewerLeft() }
    }

    private func metrics(history: [SystemSample], showsGPU: Bool) -> some View {
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
        .fixedSize(horizontal: false, vertical: true)
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 2)
            .padding(.horizontal, 14)
    }

    private static let coreCount = "\(ProcessInfo.processInfo.activeProcessorCount) cores"

    static let totalMemory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

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
        /// One app's CPU, as a share of one core (it can pass 100%).
        static let app = Scale(busy: 0.5, maxed: 0.9)
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
                .frame(height: 16)
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

/// The apps using the most CPU or memory, with what that means and a way to quit them.
private struct AppList: View {
    @Bindable var feature: SystemMonitorFeature

    static let rowHeight: CGFloat = 20

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text("USING THE MOST")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
                ForEach(AppRanking.allCases, id: \.self) { ranking in
                    Button(ranking.title) {
                        withAnimation(Motion.list) { feature.ranking = ranking }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(feature.ranking == ranking ? 0.9 : 0.35))
                }
            }
            VStack(spacing: 0) {
                let apps = feature.topApps
                if apps.isEmpty {
                    Text("Measuring…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(apps) { app in
                        AppRow(app: app, ranking: feature.ranking, state: feature.quitState(for: app)) {
                            feature.quit(app)
                        } forceQuit: {
                            feature.forceQuit(app)
                        }
                        .frame(height: Self.rowHeight)
                        .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }
            // Always three rows tall, so the notch doesn't resize as apps come and go.
            .frame(height: Self.rowHeight * CGFloat(SystemMonitorFeature.listedApps))
            .animation(Motion.list, value: feature.topApps.map(\.id))
        }
    }
}

private struct AppRow: View {
    let app: AppUsage
    let ranking: AppRanking
    let state: QuitState
    let quit: () -> Void
    let forceQuit: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: AppUsageText.icon(for: app))
                .resizable()
                .frame(width: 15, height: 15)
            Text(app.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .layoutPriority(1)
            if let hint = AppUsageText.hint(for: app, totalMemory: ProcessInfo.processInfo.physicalMemory) {
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LoadLevel.busy.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(AppUsageText.cpu(app.cpu))
                .font(.system(size: 11, weight: ranking == .cpu ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LoadLevel(app.cpu, on: .app).color.opacity(ranking == .cpu ? 1 : 0.7))
                .frame(width: 38, alignment: .trailing)
            Text(AppUsageText.memory(app.memory))
                .font(.system(size: 11, weight: ranking == .memory ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(ranking == .memory ? 0.9 : 0.5))
                .frame(width: 50, alignment: .trailing)
            Group {
                if app.canQuit {
                    QuitButton(state: state, quit: quit, forceQuit: forceQuit)
                } else {
                    Text("macOS")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .help("Part of macOS. It stops on its own when it's done.")
                }
            }
            .frame(width: 62, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Quit; Quitting… while the app gets the chance; Force Quit if it doesn't take it.
struct QuitButton: View {
    let state: QuitState
    let quit: () -> Void
    let forceQuit: () -> Void

    var body: some View {
        switch state {
        case .running:
            pill("Quit", color: .white.opacity(0.12), action: quit)
                .help("Quit, as from the Dock. The app can ask to save first.")
        case .quitting:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
                .help("Waiting for it to quit")
        case .notResponding:
            pill("Force Quit", color: LoadLevel.maxed.color, action: forceQuit)
                .help("It didn't quit. Force quitting loses unsaved changes.")
        }
    }

    private func pill(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 17)
                .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// How app usage reads. Pure, so it's unit-tested.
enum AppUsageText {
    /// Steady use of most of a core: the fans and the battery feel it.
    static let heavyCPU = 0.8
    /// A big share of installed memory: the Mac starts compressing and swapping.
    static let heavyMemoryShare = 0.2

    /// "145%", as Activity Monitor shows it.
    static func cpu(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// "806 MB" or "2.3 GB".
    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes >= 1000 ? String(format: "%.1f GB", megabytes / 1024) : "\(Int(megabytes.rounded())) MB"
    }

    /// What the numbers mean for the user, when they matter.
    static func hint(for app: AppUsage, totalMemory: UInt64) -> String? {
        if let work = app.work {
            return work.activity
        }
        if app.cpu >= heavyCPU {
            return "Heating up your Mac"
        }
        if totalMemory > 0, Double(app.memory) / Double(totalMemory) >= heavyMemoryShare {
            return "Filling memory"
        }
        return nil
    }

    @MainActor static func icon(for app: AppUsage) -> NSImage {
        if let work = app.work {
            if let id = work.appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            let white = NSImage.SymbolConfiguration(paletteColors: [.white])
            if let symbol = NSImage(systemSymbolName: work.symbol, accessibilityDescription: work.name)?
                .withSymbolConfiguration(white)
            {
                return symbol
            }
        }
        if let bundlePath = app.bundlePath {
            return NSWorkspace.shared.icon(forFile: bundlePath)
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

extension AppRanking {
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        }
    }
}
