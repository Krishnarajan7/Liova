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
    let chrome = NotchChrome()
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
            let model = SideHUDModel(edge: state.kind == .brightness ? .leading : .trailing)
            model.state = state
            model.isVisible = true
            let view = ZStack {
                LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
                SideHUDView(model: model)
            }
            .frame(width: SideHUDController.panelSize.width, height: SideHUDController.panelSize.height)
            // A first pass measures the open notch's content, which then sizes it.
            _ = ImageRenderer(content: view).nsImage
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let tiff = try #require(renderer.nsImage?.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    @Test func notchPages() throws {
        let power = FakePowerSource(PowerSnapshot(
            hasBattery: true,
            percentage: 66,
            isPluggedIn: true,
            isCharging: true
        ))
        let battery = BatteryFeature(engine: engine, settings: settings, provider: power)
        battery.start()
        let monitor = SystemMonitorFeature()
        for index in 0 ..< 60 {
            let time = Double(index)
            monitor.append(SystemSample(
                cpu: 0.12 + 0.08 * sin(time / 4) + (index % 7 == 0 ? 0.15 : 0),
                memory: 0.62 + 0.02 * sin(time / 9),
                gpu: 0.4 + 0.25 * sin(time / 6)
            ))
        }
        chrome.addPage(NotchChrome.Page(id: "system", symbol: "gauge.with.dots.needle.67percent", title: "System") {
            AnyView(SystemPage(feature: monitor))
        })
        chrome.trailingStatus = { AnyView(BatteryStatusView(feature: battery)) }
        chrome.openSettings = {}
        let provider = FakeNowPlaying()
        let media = NowPlayingFeature(engine: engine, settings: settings, provider: provider)
        renderers.register(NowPlayingRenderer(feature: media), forSource: NowPlayingPolicy.source)
        media.start()
        provider.emit(NowPlayingInfo(
            bundleIdentifier: "com.spotify.client", title: "Golden Hour", artist: "The Midnight Owls",
            duration: 240, elapsedTime: 83, timestamp: Date(), isPlaying: true
        ))
        try render("chrome-1-home", .expanded)
        try render("chrome-2-system", .expanded, page: "system")
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

    private func render(_ name: String, _ presentation: NotchPresentation, page: String? = nil) throws {
        let model = NotchModel(geometry: geometry, showsIdleVirtualNotch: true)
        model.presentation = presentation
        if let page {
            model.selectedPage = page
        }
        let size = NotchLayout.panelSize(for: geometry)
        let view = ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color(white: 0.85).frame(height: geometry.notchSize.height)
                Color(white: 0.95)
            }
            NotchRootView(model: model, engine: engine, renderers: renderers, chrome: chrome, onTap: {})
        }
        .frame(width: size.width, height: size.height)
        // A first pass measures the open notch's content, which then sizes it.
        _ = ImageRenderer(content: view).nsImage
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

/// Headphones and weather, kept apart so the suite stays readable.
extension FeatureSnapshotExport {
    @Test func headphones() throws {
        let monitor = FakeHeadphonesMonitor()
        let feature = HeadphonesFeature(engine: engine, settings: settings, monitor: monitor)
        renderers.register(HeadphonesRenderer(feature: feature), forSource: HeadphonesPolicy.source)
        chrome.addPage(NotchChrome.Page(
            id: HeadphonesPolicy.pageID, symbol: "headphones", title: "Headphones", showsInBar: false,
            content: { AnyView(HeadphonesPage(feature: feature)) }
        ))
        chrome.openSettings = {}
        chrome.trailingStatus = headerStatus(headphones: feature)
        feature.syncWithSettings()
        let earPods = HeadphonesState(id: "wired.x", name: "EarPods", kind: .earPods, isWired: true)
        monitor.send([earPods])
        try render("headphones-1-wired-closed", .closed)
        try render("headphones-2-wired-expanded", .expanded)
        monitor.send([])
        try render("headphones-3-unplugged-closed", .closed)
        monitor.send([HeadphonesState(
            id: "aa", name: "Krish's AirPods Pro", kind: .airPodsPro,
            battery: .init(left: 82, right: 78, caseLevel: 45),
            listeningMode: .noiseCancellation, availableModes: [.off, .noiseCancellation, .transparency]
        )])
        try render("headphones-4-airpods-expanded", .expanded)
        try render("headphones-5-page", .expanded, page: HeadphonesPolicy.pageID)
        engine.endAll(source: HeadphonesPolicy.source)
        engine.endAll(source: BatteryActivityPolicy.source)
        try render("headphones-6-header", .expanded, page: HeadphonesPolicy.pageID)
    }

    /// The app's header status at 100% on power, beside the given headphones.
    private func headerStatus(headphones feature: HeadphonesFeature) -> () -> AnyView {
        let power = FakePowerSource(PowerSnapshot(
            hasBattery: true,
            percentage: 100,
            isPluggedIn: true,
            isCharging: false
        ))
        let battery = BatteryFeature(engine: engine, settings: settings, provider: power)
        battery.start()
        return {
            AnyView(ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    HeadphonesStatusView(feature: feature)
                    BatteryStatusView(feature: battery)
                }
                HStack(spacing: 6) {
                    HeadphonesStatusView(feature: feature, isCompact: true)
                    BatteryStatusView(feature: battery)
                }
                HStack(spacing: 6) {
                    HeadphonesStatusView(feature: feature, isCompact: true)
                    BatteryStatusView(feature: battery, detail: .percentage)
                }
                HStack(spacing: 6) {
                    HeadphonesStatusView(feature: feature, isCompact: true)
                    BatteryStatusView(feature: battery, detail: .icon)
                }
            })
        }
    }

    @Test func weather() async throws {
        let now = Date()
        let hour = 3600.0
        let start = (now.timeIntervalSince1970 / hour).rounded(.down) * hour
        let codes: [WeatherCondition] = [.partlyCloudy, .partlyCloudy, .showers, .rain, .cloudy, .clear]
        let report = WeatherReport(
            current: .init(temperature: 28.6, feelsLike: 32.9, condition: .partlyCloudy, humidity: 78),
            hours: codes.enumerated().map { index, code in
                .init(
                    time: Date(timeIntervalSince1970: start + Double(index) * hour),
                    temperature: 28.6 - Double(index) * 0.7,
                    condition: code,
                    precipitationChance: [10, 25, 65, 80, 30, 5][index],
                    isDay: index < 4
                )
            },
            days: [.init(date: now, high: 31.2, low: 24.3, condition: .showers)],
            timeZone: .current,
            fetchedAt: now
        )
        settings.weatherEnabled = true
        settings.weatherPlace = WeatherPlace(name: "Chennai, Tamil Nadu, India", latitude: 13.08, longitude: 80.27)
        let feature = WeatherFeature(
            engine: engine, settings: settings, fetcher: FakeWeather(answer: report),
            location: { FakeLocation(.denied) }
        )
        renderers.register(WeatherRenderer(feature: feature), forSource: WeatherPolicy.source)
        chrome.addPage(NotchChrome.Page(id: WeatherPolicy.pageID, symbol: "cloud.sun.fill", title: "Weather") {
            AnyView(WeatherPage(feature: feature))
        })
        chrome.openSettings = {}
        feature.syncWithSettings()
        for _ in 0 ..< 100 where feature.report == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try render("weather-1-page", .expanded, page: WeatherPolicy.pageID)
        // Showers at 65% within two hours: the feature has already given its heads-up.
        try render("weather-2-rain-closed", .closed)
    }
}
