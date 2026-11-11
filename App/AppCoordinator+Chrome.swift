import LiovaFeatures
import LiovaUI
import SwiftUI

extension AppCoordinator {
    /// Pages and status for the open notch.
    func configureChrome() {
        let shelf = shelf
        let timers = timers
        let systemMonitor = systemMonitor
        chrome.addPage(NotchChrome.Page(id: ShelfFeature.pageID, symbol: "tray.full.fill", title: "Shelf") {
            AnyView(ShelfPage(feature: shelf))
        })
        chrome.addPage(NotchChrome.Page(id: TimerFeature.pageID, symbol: "timer", title: "Timers") {
            AnyView(TimersPage(feature: timers))
        })
        let calendar = calendar
        let settings = settings
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
        chrome.addPage(NotchChrome.Page(id: "system", symbol: "gauge.with.dots.needle.67percent", title: "System") {
            AnyView(SystemPage(feature: systemMonitor))
        })
        let clipboard = clipboard
        chrome.addPage(NotchChrome.Page(
            id: ClipboardFeature.pageID, symbol: "doc.on.clipboard.fill", title: "Clipboard",
            isAvailable: { clipboard.isEnabled },
            content: { AnyView(ClipboardPage(feature: clipboard)) }
        ))
        let recording = recording
        chrome.addPage(NotchChrome.Page(
            id: RecordingFeature.pageID, symbol: "record.circle", title: "Record",
            isAvailable: { recording.isEnabled },
            content: { AnyView(RecordingPage(feature: recording)) }
        ))
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
}
