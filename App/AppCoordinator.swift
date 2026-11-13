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

    @ObservationIgnored private lazy var settingsWindow = SettingsWindow(coordinator: self)
    @ObservationIgnored private let displayManager = DisplayManager()
    @ObservationIgnored private let renderers = ActivityRendererRegistry()
    @ObservationIgnored let chrome = NotchChrome()
    @ObservationIgnored let systemMonitor = SystemMonitorFeature()
    @ObservationIgnored let shelf = ShelfFeature()
    @ObservationIgnored lazy var timers = TimerFeature(engine: engine)
    @ObservationIgnored private lazy var welcome = WelcomeFeature(engine: engine, settings: settings)
    @ObservationIgnored lazy var calendar = CalendarFeature(engine: engine, settings: settings)
    @ObservationIgnored lazy var capture = CaptureIndicatorFeature(engine: engine, settings: settings)
    @ObservationIgnored private lazy var resourceAlerts = ResourceAlertFeature(engine: engine, settings: settings)
    @ObservationIgnored private lazy var calls = CallFeature(engine: engine, settings: settings)
    @ObservationIgnored lazy var clipboard = ClipboardFeature(settings: settings)
    @ObservationIgnored lazy var hotkeys = HotkeyFeature(settings: settings)
    @ObservationIgnored lazy var recording = RecordingFeature(engine: engine, settings: settings)
    @ObservationIgnored private lazy var unlock = UnlockFeature(engine: engine, settings: settings)
    @ObservationIgnored lazy var headphones = HeadphonesFeature(engine: engine, settings: settings)
    @ObservationIgnored private lazy var lyrics = LyricsFeature(settings: settings)
    @ObservationIgnored private(set) lazy var weather = WeatherFeature(engine: engine, settings: settings)
    @ObservationIgnored private(set) lazy var updates = UpdateFeature(engine: engine, settings: settings)
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
        provider: MediaRemoteAdapterProvider.Location.bundled().map { MediaRemoteAdapterProvider(location: $0) },
        scripting: AppleScriptRepeat()
    )
    @ObservationIgnored lazy var battery = BatteryFeature(
        engine: engine,
        settings: settings,
        provider: IOKitPowerSource()
    )
    @ObservationIgnored private lazy var executor = ActivityCommandExecutor(engine: engine)
    @ObservationIgnored private var ipcServer: IPCServer?
    @ObservationIgnored private var settingsObservation: ObservationLoop?
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false

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
        registerRenderers()
        configureChrome()
        notchSystem.start()
        battery.syncWithSettings()
        showWelcomeIfNeeded()
        Log.signposter.endInterval("launch", interval)
        // Everything else waits one run-loop turn, so the notch is on screen first; none of it
        // draws at launch, and each source delivers its current state as soon as it starts.
        DispatchQueue.main.async { [weak self] in
            self?.startBackgroundSources()
        }
    }

    private func startBackgroundSources() {
        guard !isStopped else { return }
        observeAccessibilityChanges()
        nowPlaying.syncWithSettings()
        hud.syncWithSettings()
        downloads.syncWithSettings()
        capture.syncWithSettings()
        resourceAlerts.syncWithSettings()
        calls.syncWithSettings()
        clipboard.syncWithSettings()
        recording.syncWithSettings()
        configureHotkeys()
        unlock.syncWithSettings()
        headphones.syncWithSettings()
        calendar.syncWithSettings()
        weather.syncWithSettings()
        updates.syncWithSettings()
        startPluginServer()
        observeSettings()
        Log.app.info("Liova started")
    }

    /// Every feature rechecks its settings when any of these change.
    private func observeSettings() {
        settingsObservation = ObservationLoop { [weak self] in
            guard let self else { return }
            // Reading these registers interest; any change reruns the reaction below.
            _ = (
                settings.displayPlacement,
                settings.showVirtualNotchWhenIdle,
                settings.hideInFullScreen,
                settings.notchStyle,
                settings.batteryActivitiesEnabled,
                settings.lowBatteryThreshold,
                settings.nowPlayingEnabled,
                settings.lyricsEnabled,
                settings.lyricsInClosedNotch,
                settings.hudReplacementEnabled,
                settings.agentIslandEnabled,
                settings.agentsOverMusic,
                settings.downloadsEnabled,
                settings.telegramDownloadsEnabled,
                settings.captureIndicatorEnabled,
                settings.resourceAlertsEnabled,
                settings.callControlsEnabled,
                settings.clipboardHistoryEnabled,
                settings.hotkeysEnabled,
                settings.customShortcuts,
                settings.recordingControlsEnabled,
                settings.unlockAnimationEnabled,
                settings.headphonesEnabled,
                settings.calendarEnabled,
                settings.weatherEnabled,
                settings.weatherPlace,
                settings.rainAlertsEnabled,
                settings.automaticUpdateChecks
            )
        } onChange: { [weak self] in
            self?.syncFeaturesWithSettings()
        }
    }

    private func syncFeaturesWithSettings() {
        notchSystem.settingsDidChange()
        battery.syncWithSettings()
        nowPlaying.syncWithSettings()
        lyrics.syncWithSettings()
        hud.syncWithSettings()
        agents.syncWithSettings()
        downloads.syncWithSettings()
        capture.syncWithSettings()
        resourceAlerts.syncWithSettings()
        calls.syncWithSettings()
        clipboard.syncWithSettings()
        recording.syncWithSettings()
        hotkeys.syncWithSettings()
        unlock.syncWithSettings()
        headphones.syncWithSettings()
        calendar.syncWithSettings()
        weather.syncWithSettings()
        updates.syncWithSettings()
    }

    func stop() {
        isStopped = true
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
        timers.stop()
        capture.stop()
        resourceAlerts.stop()
        calls.stop()
        clipboard.stop()
        hotkeys.stop()
        recording.stop()
        unlock.stop()
        headphones.stop()
        calendar.stop()
        weather.stop()
        updates.stop()
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

    /// First launch only: open the notch on a short welcome card.
    private func showWelcomeIfNeeded() {
        let openSettings = chrome.openSettings ?? {}
        renderers.register(
            WelcomeRenderer(feature: welcome, openSettings: openSettings),
            forSource: WelcomeFeature.source
        )
        guard welcome.showIfNeeded() else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600)) // after the panels are up
            self?.notchSystem.setAttention(true)
            try? await Task.sleep(for: .seconds(12))
            self?.notchSystem.setAttention(false)
        }
    }

    /// What each global shortcut does.
    private func configureHotkeys() {
        hotkeys.setAction(.toggleNotch) { [weak self] in self?.notchSystem.toggle(page: nil) }
        hotkeys.setAction(.clipboard) { [weak self] in self?.notchSystem.toggle(page: ClipboardFeature.pageID) }
        hotkeys.setAction(.toggleRecording) { [weak self] in self?.recording.toggleRecording() }
        hotkeys.setAction(.pauseRecording) { [weak self] in self?.recording.togglePause() }
        hotkeys.syncWithSettings()
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
}

extension AppCoordinator {
    /// Opens Settings, on `tab` when given.
    func showSettings(tab: SettingsTab? = nil) {
        settingsWindow.show(tab: tab)
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

private extension AppCoordinator {
    /// Starts plugin tier 1: the local socket that the `liova` CLI, scripts and agents talk to.
    func startPluginServer() {
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
}

extension AppCoordinator {
    /// Beside the camera in the open notch. Never squeezed: when everything doesn't fit,
    /// details drop one at a time (headphones level, charging bolt, battery percentage, then
    /// camera and mic icons become dots, then headphones and battery go), each still in its
    /// tooltip, instead of wrapping or pushing the gear past the notch's edge.
    static func trailingStatus(
        battery: BatteryFeature, capture: CaptureIndicatorFeature, headphones: HeadphonesFeature
    ) -> AnyView {
        AnyView(ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                CaptureStatusView(feature: capture)
                HeadphonesStatusView(feature: headphones)
                BatteryStatusView(feature: battery)
            }
            HStack(spacing: 6) {
                CaptureStatusView(feature: capture)
                HeadphonesStatusView(feature: headphones, isCompact: true)
                BatteryStatusView(feature: battery)
            }
            HStack(spacing: 6) {
                CaptureStatusView(feature: capture)
                HeadphonesStatusView(feature: headphones, isCompact: true)
                BatteryStatusView(feature: battery, detail: .percentage)
            }
            HStack(spacing: 6) {
                CaptureStatusView(feature: capture)
                HeadphonesStatusView(feature: headphones, isCompact: true)
                BatteryStatusView(feature: battery, detail: .icon)
            }
            HStack(spacing: 5) {
                CaptureStatusView(feature: capture, isCompact: true)
                HeadphonesStatusView(feature: headphones, isCompact: true)
                BatteryStatusView(feature: battery, detail: .icon)
            }
            // The last resort must always fit: the camera and mic dots, which matter most.
            HStack(spacing: 5) {
                CaptureStatusView(feature: capture, isCompact: true)
                BatteryStatusView(feature: battery, detail: .icon)
            }
            CaptureStatusView(feature: capture, isCompact: true)
        })
    }
}

extension AppCoordinator {
    /// Custom views for each feature's activities.
    private func registerRenderers() {
        renderers.register(NowPlayingRenderer(feature: nowPlaying, lyrics: lyrics), forSource: NowPlayingPolicy.source)
        nowPlaying.onInfoChange = { [weak self] info in self?.lyrics.update(info) }
        renderers.register(HUDRenderer(), forSource: HUDPolicy.source)
        renderers.register(BatteryRenderer(), forSource: BatteryActivityPolicy.source)
        renderers.register(TimerRenderer(feature: timers), forSource: TimerPolicy.source)
        renderers.register(CalendarRenderer(feature: calendar), forSource: CalendarPolicy.source)
        renderers.register(WeatherRenderer(feature: weather), forSource: WeatherPolicy.source)
        renderers.register(
            UpdateRenderer(feature: updates) { [weak self] in self?.showSettings(tab: .updates) },
            forSource: UpdatePolicy.source
        )
        renderers.register(DownloadsRenderer(feature: downloads), forSource: DownloadsPolicy.source)
        hud.sideHUD = { [volumeBar, brightnessBar] state in
            (state.kind == .brightness ? brightnessBar : volumeBar).show(state)
        }
        renderers.register(AgentIslandRenderer(feature: agents), forSource: AgentIslandPolicy.source)
        renderers.register(HeadphonesRenderer(feature: headphones), forSource: HeadphonesPolicy.source)
        renderers.register(ResourceAlertRenderer(feature: resourceAlerts), forSource: ResourceAlertPolicy.source)
        renderers.register(CallRenderer(feature: calls), forSource: CallPolicy.source)
        renderers.register(RecordingRenderer(feature: recording), forSource: RecordingPolicy.source)
        renderers.register(UnlockRenderer(feature: unlock), forSource: UnlockPolicy.source)
        agents.onAttentionChange = { [weak self] needed in
            self?.notchSystem.setAttention(needed)
        }
    }
}
