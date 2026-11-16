import LiovaFeatures
import LiovaUI
import SwiftUI

extension AppCoordinator {
    /// Pages and status for the open notch.
    func configureChrome() {
        let shelf = shelf
        let timers = timers
        let settings = settings
        chrome.addPage(NotchChrome.Page(id: ShelfFeature.pageID, symbol: "tray.full.fill", title: "Shelf") {
            AnyView(ShelfPage(feature: shelf))
        })
        chrome.addPage(NotchChrome.Page(id: TimerFeature.pageID, symbol: "timer", title: "Timers") {
            AnyView(TimersPage(feature: timers, settings: settings))
        })
        let calendar = calendar
        chrome.addPage(NotchChrome.Page(
            id: CalendarFeature.pageID, symbol: "calendar", title: "Calendar",
            isAvailable: { settings.calendarEnabled },
            content: { AnyView(CalendarPage(feature: calendar)) }
        ))
        let weather = weather
        chrome.addPage(NotchChrome.Page(
            id: WeatherPolicy.pageID, symbol: "cloud.sun.fill", title: "Weather",
            isAvailable: { settings.weatherEnabled },
            content: { AnyView(WeatherPage(feature: weather)) }
        ))
        addToolPages()
        chrome.dropPageID = ShelfFeature.pageID
        let battery = battery
        let capture = capture
        let headphones = headphones
        chrome.addPage(NotchChrome.Page(
            id: HeadphonesPolicy.pageID, symbol: "headphones", title: "Headphones", showsInBar: false,
            isAvailable: { headphones.isConnected },
            content: { AnyView(HeadphonesPage(feature: headphones)) }
        ))
        chrome.trailingStatus = {
            Self.trailingStatus(battery: battery, capture: capture, headphones: headphones)
        }
        chrome.openSettings = { [weak self] in self?.showSettings() }
    }

    /// System, Clipboard, Sound and Record.
    private func addToolPages() {
        let systemMonitor = systemMonitor
        chrome.addPage(NotchChrome.Page(id: "system", symbol: "gauge.with.dots.needle.67percent", title: "System") {
            AnyView(SystemPage(feature: systemMonitor))
        })
        let clipboard = clipboard
        chrome.addPage(NotchChrome.Page(
            id: ClipboardFeature.pageID, symbol: "doc.on.clipboard.fill", title: "Clipboard",
            isAvailable: { clipboard.isEnabled },
            content: { AnyView(ClipboardPage(feature: clipboard)) }
        ))
        let sound = sound
        chrome.addPage(NotchChrome.Page(
            id: SoundFeature.pageID, symbol: "speaker.wave.2.fill", title: "Sound",
            isAvailable: { sound.isEnabled },
            content: { AnyView(SoundPage(feature: sound)) }
        ))
        let recording = recording
        chrome.addPage(NotchChrome.Page(
            id: RecordingFeature.pageID, symbol: "record.circle", title: "Record",
            isAvailable: { recording.isEnabled },
            content: { AnyView(RecordingPage(feature: recording)) }
        ))
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
