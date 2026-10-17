import AppKit
import LiovaCore
@testable import LiovaFeatures
import LiovaPluginKit
import LiovaProviders
@testable import LiovaUI
import SwiftUI
import Testing

/// Renders feature states (Now Playing, HUDs, Agent Island) to PNG for visual review.
/// Skipped unless `LIOVA_SNAPSHOT_DIR` is set (see SnapshotExport in LiovaUITests).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] != nil))
struct FeatureSnapshotExport {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] ?? "/tmp")
    let geometry = NotchGeometry(metrics: ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        safeAreaTop: 38,
        auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 751, height: 38),
        auxiliaryTopRight: CGRect(x: 960, y: 1074, width: 750, height: 38)
    ))
    let engine = ActivityEngine()
    let renderers = ActivityRendererRegistry()
    let settings: LiovaSettings

    init() throws {
        settings = try LiovaSettings(defaults: #require(UserDefaults(suiteName: "snap.\(UUID())")))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func nowPlaying() async throws {
        let provider = FakeNowPlaying()
        let feature = NowPlayingFeature(engine: engine, settings: settings, provider: provider)
        renderers.register(NowPlayingRenderer(feature: feature), forSource: NowPlayingPolicy.source)
        feature.start()
        var info = NowPlayingInfo(
            bundleIdentifier: "com.spotify.client", title: "Golden Hour", artist: "The Midnight Owls",
            duration: 241, elapsedTime: 83, timestamp: Date(), isPlaying: true
        )
        info.artworkData = Self.gradientPNG()
        provider.emit(info)
        for _ in 0 ..< 100 where feature.artwork == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try render("media-1-closed", .closed)
        try render("media-2-expanded", .expanded)
        try engine.start(Activity(
            id: "build", source: "cli", title: "Building Liova", symbol: "hammer.fill", progress: 0.4, tint: .blue
        ))
        try render("media-3-preempted-expanded", .expanded)
    }

    @Test func huds() throws {
        renderers.register(HUDRenderer(), forSource: HUDPolicy.source)
        try engine.start(HUDPolicy.volumeActivity(volume: 0.625, isMuted: false, now: Date()))
        try render("hud-1-volume", .closed)
        try engine.start(HUDPolicy.brightnessActivity(brightness: 0.3, now: Date()))
        try render("hud-2-brightness", .closed)
    }

    @Test func chargingMoment() async throws {
        renderers.register(BatteryRenderer(), forSource: BatteryActivityPolicy.source)
        let provider = FakeNowPlaying()
        let media = NowPlayingFeature(engine: engine, settings: settings, provider: provider)
        renderers.register(NowPlayingRenderer(feature: media), forSource: NowPlayingPolicy.source)
        media.start()
        provider.emit(NowPlayingInfo(
            bundleIdentifier: "com.spotify.client", title: "Golden Hour", artist: "The Midnight Owls",
            duration: 270, elapsedTime: 40, timestamp: Date(), isPlaying: true
        ))
        let plugIn = BatteryActivityPolicy.actions(
            from: PowerSnapshot(hasBattery: true, percentage: 66, isPluggedIn: false, isCharging: false),
            to: PowerSnapshot(hasBattery: true, percentage: 66, isPluggedIn: true, isCharging: true),
            lowThreshold: 20, now: Date()
        )
        for case let .start(activity) in plugIn {
            try engine.start(activity)
        }
        try await Task.sleep(for: .milliseconds(1500)) // let the one-shot fill settle
        try render("battery-1-charging-closed", .closed)
        try render("battery-2-charging-expanded-keeps-music", .expanded)
    }

    @Test func sideHUD() throws {
        for (name, state) in [
            ("sidehud-1-volume-high", SideHUDState(kind: .volume, level: 0.85, symbol: "speaker.wave.3.fill")),
            ("sidehud-2-volume-low", SideHUDState(kind: .volume, level: 0.25, symbol: "speaker.wave.1.fill")),
            ("sidehud-3-brightness", SideHUDState(kind: .brightness, level: 0.6, symbol: "sun.max.fill")),
        ] {
            let model = SideHUDModel()
            model.state = state
            model.isVisible = true
            let view = ZStack {
                LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
                SideHUDView(model: model)
            }
            .frame(width: SideHUDController.panelSize.width, height: SideHUDController.panelSize.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let tiff = try #require(renderer.nsImage?.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    @Test func agentIsland() async throws {
        let agents = AgentIslandFeature(engine: engine, settings: settings)
        renderers.register(AgentIslandRenderer(feature: agents), forSource: AgentIslandPolicy.source)
        agents.handle(AgentEvent(
            agent: "claude-code", sessionID: "s", project: "Liova", kind: .toolStarted, detail: "Running `swift test`"
        ))
        try render("agent-1-working-closed", .closed)
        try render("agent-2-working-expanded", .expanded)
        let request = Task {
            await agents.requestPermission(AgentPermissionRequest(
                agent: "claude-code", sessionID: "s", project: "Liova", tool: "Bash",
                summary: "git push origin main && gh release create v0.2.0 --notes-file CHANGELOG.md", timeout: 60
            ))
        }
        for _ in 0 ..< 100 where agents.prompts.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try render("agent-3-permission-closed", .closed)
        try render("agent-4-permission-expanded", .expanded)
        agents.stop()
        _ = await request.value
    }

    private func render(_ name: String, _ presentation: NotchPresentation) throws {
        let model = NotchModel(geometry: geometry, showsIdleVirtualNotch: true)
        model.presentation = presentation
        let size = NotchLayout.panelSize(for: geometry)
        let view = ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color(white: 0.85).frame(height: geometry.notchSize.height)
                Color(white: 0.95)
            }
            NotchRootView(model: model, engine: engine, renderers: renderers, onTap: {})
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    static func gradientPNG() -> Data? {
        let size = 300
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 0.95, green: 0.3, blue: 0.4, alpha: 1),
                CGColor(red: 0.3, green: 0.2, blue: 0.8, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        ) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
