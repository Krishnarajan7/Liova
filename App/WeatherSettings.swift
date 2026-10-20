import LiovaCore
import LiovaFeatures
import SwiftUI

/// Settings > Weather: on or off, where, units, and the rain heads-up.
struct WeatherSettings: View {
    @Bindable var settings: LiovaSettings
    let weather: WeatherFeature
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isChoosingCity = false

    var body: some View {
        Form {
            Section {
                Toggle("Weather", isOn: $settings.weatherEnabled)
                Toggle("Heads-up before rain", isOn: $settings.rainAlertsEnabled)
                    .disabled(!settings.weatherEnabled)
                Picker("Temperature", selection: $settings.temperatureUnit) {
                    Text("Automatic").tag(TemperatureUnit.automatic)
                    Text("Celsius").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                }
                .disabled(!settings.weatherEnabled)
            } footer: {
                Text(
                    "A Weather page in the open notch with the next hours, and a short heads-up in the notch "
                        + "when rain is about to start. Weather data by Open-Meteo.com (CC BY 4.0)."
                )
            }
            Section {
                Picker("Location", selection: usesCurrentLocation) {
                    Text("Approximate current location").tag(true)
                    Text(settings.weatherPlace?.name ?? "A city…").tag(false)
                }
                .pickerStyle(.radioGroup)
                if isChoosingCity || settings.weatherPlace != nil {
                    citySearch
                }
            } footer: {
                Text(
                    "Current location asks macOS once, uses reduced accuracy, and is rounded to about a kilometre "
                        + "before it's sent. A city sends only that city's position."
                )
            }
            .disabled(!settings.weatherEnabled)
        }
        .formStyle(.grouped)
    }

    /// True for the current location, false for a picked city. Picking "A city…" keeps the
    /// current location until a city is chosen below.
    private var usesCurrentLocation: Binding<Bool> {
        Binding(
            get: { settings.weatherPlace == nil && !isChoosingCity },
            set: { useCurrent in
                isChoosingCity = !useCurrent
                if useCurrent {
                    settings.weatherPlace = nil
                }
            }
        )
    }

    @ViewBuilder
    private var citySearch: some View {
        TextField("Search for a city", text: $query)
            .onSubmit(search)
            .onChange(of: query) { search() }
        if isSearching, results.isEmpty {
            ProgressView().controlSize(.small)
        }
        ForEach(results) { place in
            Button {
                settings.weatherPlace = place
                isChoosingCity = false
                query = ""
                results = []
            } label: {
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                    Text(place.name)
                    Spacer()
                    if place == settings.weatherPlace {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Waits for a pause in typing, then asks.
    private func search() {
        searchTask?.cancel()
        let text = query
        guard text.trimmingCharacters(in: .whitespaces).count >= 2 else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isSearching = true
            let found = await weather.places(named: text)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
