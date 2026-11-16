import LiovaCore
import LiovaFeatures
import SwiftUI

/// Settings → Activities: the cities on the Timers page's world clock.
struct WorldClockSettings: View {
    @Bindable var settings: LiovaSettings

    var body: some View {
        Section {
            ForEach(settings.worldClockCities, id: \.self) { zoneID in
                HStack {
                    Text(WorldClockPolicy.city(for: zoneID))
                    Text(zoneID.split(separator: "/").first.map(String.init) ?? "")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        settings.worldClockCities.removeAll { $0 == zoneID }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(WorldClockPolicy.city(for: zoneID))")
                    .accessibilityLabel(Text("Remove \(WorldClockPolicy.city(for: zoneID))"))
                }
            }
            Menu("Add a city") {
                ForEach(WorldClockPolicy.regions(), id: \.name) { region in
                    Menu(region.name) {
                        ForEach(region.zoneIDs, id: \.self) { zoneID in
                            Button(WorldClockPolicy.city(for: zoneID)) {
                                settings.worldClockCities.append(zoneID)
                            }
                            .disabled(settings.worldClockCities.contains(zoneID))
                        }
                    }
                }
            }
            .disabled(settings.worldClockCities.count >= WorldClockPolicy.maxCities)
        } header: {
            Text("World clock")
        } footer: {
            Text(
                "The time in up to \(WorldClockPolicy.maxCities) cities, on the Timers page of the open notch. "
                    + "Remove them all to hide it."
            )
        }
    }
}
