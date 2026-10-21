import LiovaCore
import LiovaFeatures
import SwiftUI

/// The Settings window's tabs, so other parts of the app can open one.
enum SettingsTab: Hashable {
    case general, activities, huds, weather, agents, updates, about
}

struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        TabView(selection: $coordinator.settingsTab) {
            GeneralSettings(settings: coordinator.settings, launchAtLogin: coordinator.launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ActivitySettings(settings: coordinator.settings, nowPlaying: coordinator.nowPlaying)
                .tabItem { Label("Activities", systemImage: "bolt.horizontal") }
                .tag(SettingsTab.activities)
            HUDSettings(settings: coordinator.settings, hud: coordinator.hud)
                .tabItem { Label("HUDs", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.huds)
            WeatherSettings(settings: coordinator.settings, weather: coordinator.weather)
                .tabItem { Label("Weather", systemImage: "cloud.sun") }
                .tag(SettingsTab.weather)
            AgentSettings(settings: coordinator.settings)
                .tabItem { Label("Agents", systemImage: "sparkle") }
                .tag(SettingsTab.agents)
            UpdateSettings(settings: coordinator.settings, updates: coordinator.updates)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.updates)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { NSApp.activate() }
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: LiovaSettings
    let launchAtLogin: LaunchAtLogin

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
        }
        .formStyle(.grouped)
    }
}

private struct ActivitySettings: View {
    @Bindable var settings: LiovaSettings
    let nowPlaying: NowPlayingFeature

    var body: some View {
        Form {
            Section {
                Toggle("Now Playing", isOn: $settings.nowPlayingEnabled)
                Picker("Moving music bars", selection: $settings.musicBars) {
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
            Section {
                Toggle("Camera and microphone in use", isOn: $settings.captureIndicatorEnabled)
            } footer: {
                Text(
                    "Flashes the notch when any app turns on the camera or microphone. "
                        + "Handy in full-screen apps, where the menu bar's indicator is hidden."
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

private struct AgentSettings: View {
    @Bindable var settings: LiovaSettings
    @State private var connections = AgentConnections()

    var body: some View {
        Form {
            Section {
                Toggle("Show coding agents in the notch", isOn: $settings.agentIslandEnabled)
                Toggle("Open the notch when an agent asks for permission", isOn: $settings.agentOpensNotchForApprovals)
                    .disabled(!settings.agentIslandEnabled)
            } footer: {
                Text(
                    "See what your coding agents are doing and approve or deny requests from the notch. "
                        + "If you don't answer, the agent asks in its terminal as usual."
                )
            }
            Section {
                ForEach(AgentConnections.agents) { agent in
                    AgentRow(agent: agent, connections: connections)
                }
            } header: {
                Text("Connect your agents")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Connecting adds Liova's hooks to the agent's settings file and keeps a backup. "
                            + "Only event types, the project folder name and a short tool summary are shared, "
                            + "never your prompts."
                    )
                    if !connections.isInApplications {
                        Text(
                            "Move Liova to your Applications folder before connecting, so the connection keeps working."
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { connections.refresh() }
    }
}

private struct AgentRow: View {
    let agent: AgentConnections.Agent
    let connections: AgentConnections

    var body: some View {
        let status = connections.statuses[agent.id] ?? .checking
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                Text(agent.approvals ? "Status and approvals" : "Status only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
                Button("Disconnect") { connections.disconnect(agent.id) }
                    .disabled(connections.busy.contains(agent.id))
            case .connectedElsewhere:
                Text("Connected (another copy)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("The hooks run a different copy of liova. Update to use this app's.")
                Button("Update") { connections.connect(agent.id) }
                    .disabled(connections.busy.contains(agent.id))
            case .notConnected:
                Button("Connect") { connections.connect(agent.id) }
                    .disabled(connections.busy.contains(agent.id))
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { connections.connect(agent.id) }
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
