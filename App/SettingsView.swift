import LiovaCore
import LiovaFeatures
import SwiftUI

struct SettingsView: View {
    let coordinator: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettings(settings: coordinator.settings, launchAtLogin: coordinator.launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }
            ActivitySettings(settings: coordinator.settings, nowPlaying: coordinator.nowPlaying)
                .tabItem { Label("Activities", systemImage: "bolt.horizontal") }
            HUDSettings(settings: coordinator.settings, hud: coordinator.hud)
                .tabItem { Label("HUDs", systemImage: "speaker.wave.2") }
            AgentSettings(settings: coordinator.settings)
                .tabItem { Label("Agents", systemImage: "sparkle") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
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
                Toggle("Animated music bars", isOn: $settings.animatedMusicBars)
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

    var body: some View {
        Form {
            Section {
                Toggle("Show coding agents in the notch", isOn: $settings.agentIslandEnabled)
                Toggle("Open the notch when an agent asks for permission", isOn: $settings.agentOpensNotchForApprovals)
                    .disabled(!settings.agentIslandEnabled)
            } footer: {
                Text(
                    "See what Claude Code is doing and approve or deny its requests from the notch. "
                        + "If you don't answer, the agent asks in its terminal as usual."
                )
            }
            Section("Set up") {
                LabeledContent("Claude Code") {
                    Text("liova agents install claude-code")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("Run this once in Terminal. It adds Liova's hooks to ~/.claude/settings.json and keeps a backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "capsule.inset.filled")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Liova").font(.title2.bold())
            Text("Version \(Bundle.main.shortVersion)").foregroundStyle(.secondary)
            Text("A free, open-source Dynamic Island for your Mac.")
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
            Text("MIT License · No telemetry")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
