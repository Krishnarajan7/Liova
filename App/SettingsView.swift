import LiovaCore
import LiovaFeatures
import SwiftUI

/// The Settings window's tabs, so other parts of the app can open one.
enum SettingsTab: Hashable, CaseIterable {
    case general, activities, huds, weather, agents, updates, about

    var title: String {
        switch self {
        case .general: "General"
        case .activities: "Activities"
        case .huds: "HUDs"
        case .weather: "Weather"
        case .agents: "Agents"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .activities: "bolt.horizontal"
        case .huds: "speaker.wave.2"
        case .weather: "cloud.sun"
        case .agents: "sparkle"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }
}

/// One tab of the Settings window (see `SettingsWindow`).
struct SettingsPane: View {
    let tab: SettingsTab
    let coordinator: AppCoordinator
    /// How tall the tab would be with everything showing.
    @State private var naturalHeight: CGFloat?

    /// Short tabs fit their content; long ones stop at the screen's height and scroll.
    var body: some View {
        content
            .frame(width: 460, height: naturalHeight.map { min($0, Self.maxHeight) })
            .background {
                content
                    .frame(width: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
            }
    }

    /// The screen's height, less the title bar and tabs, and a margin.
    private static var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 160
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            GeneralSettings(
                settings: coordinator.settings, launchAtLogin: coordinator.launchAtLogin, hotkeys: coordinator.hotkeys
            )
        case .activities:
            ActivitySettings(
                settings: coordinator.settings, nowPlaying: coordinator.nowPlaying, recording: coordinator.recording
            )
        case .huds: HUDSettings(settings: coordinator.settings, hud: coordinator.hud)
        case .weather: WeatherSettings(settings: coordinator.settings, weather: coordinator.weather)
        case .agents: AgentSettings(settings: coordinator.settings)
        case .updates: UpdateSettings(settings: coordinator.settings, updates: coordinator.updates)
        case .about: AboutSettings()
        }
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: LiovaSettings
    let launchAtLogin: LaunchAtLogin
    let hotkeys: HotkeyFeature

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.set($0) }
                ))
                if let error = launchAtLogin.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Notch") {
                Picker("Look", selection: $settings.notchStyle) {
                    Text("Black").tag(NotchStyle.black)
                    Text("Glass").tag(NotchStyle.glass)
                }
                .pickerStyle(.segmented)
                .help("Glass shows the desktop through the open notch. Closed, it stays black to match the camera.")
                Picker("Show on", selection: $settings.displayPlacement) {
                    Text("All displays").tag(DisplayPlacement.allDisplays)
                    Text("Built-in display").tag(DisplayPlacement.builtInOnly)
                    Text("Main display").tag(DisplayPlacement.mainOnly)
                }
                Toggle("Show the notch on displays without a camera housing", isOn: $settings.showVirtualNotchWhenIdle)
                Toggle("Hide over full-screen apps until hovered", isOn: $settings.hideInFullScreen)
            }
            Section("Interaction") {
                Toggle("Open on hover", isOn: $settings.openOnHover)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $settings.hoverDelay, in: LiovaSettings.hoverDelayRange, step: 0.02)
                        Text(settings.hoverDelay, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                        Text("s").foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.openOnHover)
                Toggle("Haptic feedback on trackpads", isOn: $settings.hapticsEnabled)
            }
            if PreviewFeature.hotkeys.isEnabled() {
                ShortcutSection(settings: settings, hotkeys: hotkeys)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ActivitySettings: View {
    @Bindable var settings: LiovaSettings
    let nowPlaying: NowPlayingFeature
    let recording: RecordingFeature

    var body: some View {
        Form {
            Section {
                Toggle("Now Playing", isOn: $settings.nowPlayingEnabled)
                Picker("Moving music wave", selection: $settings.musicBars) {
                    Text("Always").tag(MusicBarsMode.always)
                    Text("When plugged in").tag(MusicBarsMode.pluggedIn)
                    Text("Off").tag(MusicBarsMode.off)
                }
                .disabled(!settings.nowPlayingEnabled)
            } footer: {
                if nowPlaying.isAvailable {
                    Text("Shows music, podcasts and video from any app, with artwork and controls.")
                } else {
                    Text("Now Playing isn't available in this build. Run `make vendor` and rebuild.")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Synced lyrics", isOn: $settings.lyricsEnabled)
                    .disabled(!settings.nowPlayingEnabled)
                Toggle("Show the line being sung under the closed notch", isOn: $settings.lyricsInClosedNotch)
                    .disabled(!settings.nowPlayingEnabled || !settings.lyricsEnabled)
            } footer: {
                Text(
                    "Shows the words line by line in the open notch, and the current line under the closed one "
                        + "while it's sung. Looks up the song's title, artist, album and length on lrclib.net, "
                        + "a free lyrics database, and keeps the answer on your Mac. Nothing else is sent."
                )
            }
            Section {
                Toggle("Downloads", isOn: $settings.downloadsEnabled)
                Toggle("Include Telegram downloads", isOn: $settings.telegramDownloadsEnabled)
                    .disabled(!settings.downloadsEnabled)
            } footer: {
                Text(
                    "Shows downloads from your browsers (and Telegram, if you turn it on) with progress "
                        + "and speed. Liova only looks at file names and sizes, never their contents. "
                        + "For Telegram, macOS asks once whether Liova may see another app's data."
                )
            }
            Section {
                Toggle("Calendar: show what's next", isOn: $settings.calendarEnabled)
            } footer: {
                Text(
                    "Your next meeting appears ten minutes before it starts, with a Join button for video calls. "
                        + "Liova asks for calendar access when you turn this on; events never leave your Mac."
                )
            }
            Section {
                Toggle("AirPods and headphones", isOn: $settings.headphonesEnabled)
            } footer: {
                Text(
                    "Shows headphones when they connect, Bluetooth or wired (USB-C EarPods, USB headsets, "
                        + "the headphone jack), with each bud's and the case's battery, warns when they run low, "
                        + "and switches noise control on AirPods that have it. "
                        + "macOS asks for Bluetooth access the first time."
                )
            }
            if PreviewFeature.calls.isEnabled() {
                Section {
                    Toggle("Calls: mute and hang up from the notch", isOn: $settings.callControlsEnabled)
                } footer: {
                    Text(
                        "While an app records from the microphone, the notch shows the call, how long it's run "
                            + "and whether you're muted. Mute works in every app; Hang Up presses the app's own "
                            + "Leave button, which needs Accessibility access."
                    )
                }
            }
            if PreviewFeature.clipboard.isEnabled() {
                Section {
                    Toggle("Clipboard history", isOn: $settings.clipboardHistoryEnabled)
                } footer: {
                    Text(
                        "Keeps the last 30 things you copy, to copy again from the notch's Clipboard page. "
                            + "Only in memory: forgotten when Liova quits, except what you pin. "
                            + "Passwords and anything copied in a password manager are never kept."
                    )
                }
            }
            if PreviewFeature.recording.isEnabled() {
                RecordingSection(settings: settings, recording: recording)
            }
            Section {
                Toggle("Camera and microphone in use", isOn: $settings.captureIndicatorEnabled)
            } footer: {
                Text(
                    "Flashes the notch when any app turns on the camera or microphone. "
                        + "Handy in full-screen apps, where the menu bar's indicator is hidden."
                )
            }
            Section {
                Toggle("Apps heating up the Mac", isOn: $settings.resourceAlertsEnabled)
            } footer: {
                Text(
                    "Says which app when one keeps the processor busy for minutes, or fills memory "
                        + "while it's running short, and lets you quit it from the notch. "
                        + "The System page always lists the apps using the most."
                )
            }
            Section {
                Toggle("Battery and charging", isOn: $settings.batteryActivitiesEnabled)
                Stepper(value: $settings.lowBatteryThreshold, in: 5 ... 50, step: 5) {
                    LabeledContent("Low battery warning", value: "\(settings.lowBatteryThreshold)%")
                }
                .disabled(!settings.batteryActivitiesEnabled)
            } footer: {
                Text("Shows a brief activity when you plug in or unplug, and stays visible while the battery is low.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct HUDSettings: View {
    @Bindable var settings: LiovaSettings
    let hud: HUDFeature

    var body: some View {
        Form {
            Section {
                Toggle("Replace the volume and brightness overlays", isOn: $settings.hudReplacementEnabled)
                    .disabled(HUDFeature.isSafeModeRequested)
                Picker("Style", selection: $settings.hudStyle) {
                    Text("Side bar").tag(HUDStyle.sideBar)
                    Text("In the notch").tag(HUDStyle.notch)
                }
                .disabled(!settings.hudReplacementEnabled)
                if settings.hudReplacementEnabled {
                    status
                }
            } footer: {
                Text(
                    "Replaces the system overlays when you press the volume or brightness keys. "
                        + "Liova only sees those keys, never what you type. "
                        + "If anything goes wrong, the system overlay comes back on its own."
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        if HUDFeature.isSafeModeRequested {
            Label("Safe mode: HUDs are off for this launch.", systemImage: "lifepreserver")
                .foregroundStyle(.orange)
        } else {
            switch hud.state {
            case .running:
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .needsPermission:
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Liova needs the Accessibility permission to read the volume and brightness keys.",
                        systemImage: "hand.raised.fill"
                    )
                    .foregroundStyle(.orange)
                    Button("Grant Access…") { hud.requestPermission() }
                    Text(
                        "Already switched on in System Settings? Development builds change identity "
                            + "when rebuilt: remove Liova from the list with −, then grant access again."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case let .unavailable(reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .off:
                EmptyView()
            }
        }
    }
}

private struct AboutSettings: View {
    @State private var showsLicenses = false

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Liova").font(.title2.bold())
            Text("Version \(Bundle.main.shortVersion)").foregroundStyle(.secondary)
            Text("The free, open-source notch for your Mac.")
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/Krishnarajan7/Liova")!)
                Link("Star on GitHub", destination: URL(string: "https://github.com/Krishnarajan7/Liova/stargazers")!)
                Link(
                    "Report an issue",
                    destination: URL(string: "https://github.com/Krishnarajan7/Liova/issues/new/choose")!
                )
            }
            .font(.callout)
            HStack(spacing: 6) {
                Text("MIT License · No telemetry ·")
                Button("Licenses") { showsLicenses = true }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showsLicenses) { LicensesView() }
    }
}
