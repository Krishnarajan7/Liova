import AppKit
import LiovaCore
import LiovaFeatures
import LiovaIPC
import LiovaPluginKit
import LiovaProviders
import LiovaUI
import Observation
import SwiftUI

/// Builds and owns every long-lived object. The only place where modules meet.
@MainActor
@Observable
final class AppCoordinator {
    let settings = LiovaSettings()
    let engine = ActivityEngine()
    let launchAtLogin = LaunchAtLogin()

    @ObservationIgnored private let displayManager = DisplayManager()
    @ObservationIgnored private let renderers = ActivityRendererRegistry()
    @ObservationIgnored private let chrome = NotchChrome()
    @ObservationIgnored private let systemMonitor = SystemMonitorFeature()
    @ObservationIgnored private lazy var notchSystem = NotchSystem(
        engine: engine,
        settings: settings,
        displayManager: displayManager,
        renderers: renderers,
        chrome: chrome
    )
    /// Created at launch: it checks for safe mode (Option held) only once, in `init`.
    let hud: HUDFeature
    let agents: AgentIslandFeature
    let downloads: DownloadsFeature
    /// Nil provider when the adapter isn't bundled (e.g. a build without `make vendor`).
    @ObservationIgnored private(set) lazy var nowPlaying = NowPlayingFeature(
        engine: engine,
        settings: settings,
        provider: MediaRemoteAdapterProvider.Location.bundled().map { MediaRemoteAdapterProvider(location: $0) }
    )
    @ObservationIgnored private lazy var battery = BatteryFeature(
        engine: engine,
        settings: settings,
        provider: IOKitPowerSource()
    )
    @ObservationIgnored private lazy var executor = ActivityCommandExecutor(engine: engine)
    @ObservationIgnored private var ipcServer: IPCServer?
    @ObservationIgnored private var settingsObservation: ObservationLoop?
    @ObservationIgnored private var demoTask: Task<Void, Never>?

    @ObservationIgnored private var accessibilityObserver: (any NSObjectProtocol)?
    /// Volume on the right edge, brightness on the left.
    @ObservationIgnored private let volumeBar = SideHUDController(edge: .trailing)
    @ObservationIgnored private let brightnessBar = SideHUDController(edge: .leading)

    init() {
        hud = HUDFeature(engine: engine, settings: settings)
        agents = AgentIslandFeature(engine: engine, settings: settings)
        downloads = DownloadsFeature(engine: engine, settings: settings)
    }

    func start() {
        let interval = Log.signposter.beginInterval("launch")
        renderers.register(NowPlayingRenderer(feature: nowPlaying), forSource: NowPlayingPolicy.source)
        renderers.register(HUDRenderer(), forSource: HUDPolicy.source)
        renderers.register(BatteryRenderer(), forSource: BatteryActivityPolicy.source)
        renderers.register(DownloadsRenderer(feature: downloads), forSource: DownloadsPolicy.source)
        hud.sideHUD = { [volumeBar, brightnessBar] state in
            (state.kind == .brightness ? brightnessBar : volumeBar).show(state)
        }
        renderers.register(AgentIslandRenderer(feature: agents), forSource: AgentIslandPolicy.source)
        agents.onAttentionChange = { [weak self] needed in
            self?.notchSystem.setAttention(needed)
        }
        observeAccessibilityChanges()
        configureChrome()
        notchSystem.start()
        battery.syncWithSettings()
        nowPlaying.syncWithSettings()
        hud.syncWithSettings()
        downloads.syncWithSettings()
        startPluginServer()
        settingsObservation = ObservationLoop { [weak self] in
            guard let self else { return }
            // Reading these registers interest; any change reruns the reaction below.
            _ = (
                settings.displayPlacement,
                settings.showVirtualNotchWhenIdle,
                settings.batteryActivitiesEnabled,
                settings.lowBatteryThreshold,
                settings.nowPlayingEnabled,
                settings.hudReplacementEnabled,
                settings.agentIslandEnabled,
                settings.downloadsEnabled,
                settings.telegramDownloadsEnabled
            )
        } onChange: { [weak self] in
            self?.notchSystem.settingsDidChange()
            self?.battery.syncWithSettings()
            self?.nowPlaying.syncWithSettings()
            self?.hud.syncWithSettings()
            self?.agents.syncWithSettings()
            self?.downloads.syncWithSettings()
        }
        Log.signposter.endInterval("launch", interval)
        Log.app.info("Liova started")
    }

    func stop() {
        demoTask?.cancel()
        ipcServer?.stop()
        ipcServer = nil
        settingsObservation = nil
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        battery.stop()
        nowPlaying.stop()
        hud.stop()
        agents.stop()
        downloads.stop()
        notchSystem.stop()
    }

    /// Handles a `liova://` link. Links are low-trust, so the executor limits what they can do.
    func open(_ url: URL) {
        do {
            let command = try LiovaURL.command(from: url)
            let response = executor.execute(command, origin: .url(source: LiovaURL.source))
            if let error = response.error {
                Log.app.notice("Link rejected: \(error.message, privacy: .public)")
            }
        } catch {
            Log.app.notice("Invalid link: \(error.message, privacy: .public)")
        }
    }

    /// Pages and status for the open notch.
    private func configureChrome() {
        let systemMonitor = systemMonitor
        chrome.addPage(NotchChrome.Page(id: "system", symbol: "gauge.with.dots.needle.67percent", title: "System") {
            AnyView(SystemPage(feature: systemMonitor))
        })
        let battery = battery
        chrome.trailingStatus = { AnyView(BatteryStatusView(feature: battery)) }
        chrome.openSettings = {
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// macOS posts this when any app's Accessibility trust changes, so Liova notices the
    /// moment the user grants it in System Settings, without polling.
    private func observeAccessibilityChanges() {
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The trust database updates just after the notification.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.hud.recheckPermission()
            }
        }
    }

    /// Starts plugin tier 1: the local socket that the `liova` CLI, scripts and agents talk to.
    private func startPluginServer() {
        let executor = executor
        let agents = agents
        let server = IPCServer(handler: IPCClosureHandler { command, _ in
            switch command {
            case let .agentEvent(event):
                await agents.handle(event)
                return .success()
            case let .agentPermission(request):
                return await .decided(agents.requestPermission(request))
            default:
                return await executor.execute(command, origin: .socket)
            }
        })
        do {
            try server.start()
            ipcServer = server
            Log.app.info("Plugin socket listening at \(server.socketURL.path, privacy: .public)")
        } catch {
            // Liova still works without the socket; only external activities are unavailable.
            Log.app.error("Plugin socket failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    /// A short, self-ending activity so new users can see what Liova does.
    func runDemo() {
        demoTask?.cancel()
        let id: ActivityID = "liova.demo"
        demoTask = Task { [engine] in
            do {
                try engine.start(Activity(
                    id: id,
                    source: "liova.demo",
                    title: "Exporting video",
                    subtitle: "Demo activity",
                    symbol: "film.stack",
                    progress: 0,
                    tint: .purple,
                    expiresAt: .now + 30
                ))
                for step in 1 ... 40 {
                    try await Task.sleep(for: .milliseconds(100))
                    try engine.update(id) { $0.progress = Double(step) / 40 }
                }
                try engine.update(id) {
                    $0.title = "Export complete"
                    $0.symbol = "checkmark.circle.fill"
                    $0.tint = .green
                    $0.subtitle = "Demo activity"
                    $0.expiresAt = .now + 3
                }
            } catch {
                engine.end(id)
            }
        }
    }
}

/// Re-runs `onChange` every time a value read in `track` changes, until the loop is released.
@MainActor
final class ObservationLoop {
    private let track: @MainActor () -> Void
    private let onChange: @MainActor () -> Void

    init(track: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        self.track = track
        self.onChange = onChange
        observe()
    }

    private func observe() {
        withObservationTracking(track) { [weak self] in
            // Called before the change is applied; react on the next main-actor turn.
            Task { @MainActor in
                // Once the loop is released, `self` is nil and observation stops.
                guard let self else { return }
                self.onChange()
                self.observe()
            }
        }
    }
}
