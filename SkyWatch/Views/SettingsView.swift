import SwiftUI

struct SettingsView: View {
    @Environment(ScanStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings

        List {
            Section {
                Picker("Radius", selection: $settings.radius) {
                    ForEach(ScanRadius.allCases) { radius in
                        Text("\(Int(radius.nauticalMiles)) nm").tag(radius)
                    }
                }
                Picker("Refresh", selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Picker("Units", selection: $settings.unitSystem) {
                    ForEach(UnitSystem.allCases) { system in
                        Text(system.title).tag(system)
                    }
                }
            } header: {
                sectionHeader("Scan")
            }

            Section {
                Toggle("Heading up", isOn: $settings.isHeadingUp)
                Toggle("Hide ground traffic", isOn: $settings.hidesGroundTraffic)
                Toggle("Military only", isOn: $settings.showsMilitaryOnly)
                Toggle("Include MLAT & estimated", isOn: $settings.includesUncertainTargets)
            } header: {
                sectionHeader("Scope")
            }

            Section {
                Toggle("Proximity haptic", isOn: $settings.hapticAlertsEnabled)
                if settings.hapticAlertsEnabled {
                    Picker("Distance", selection: $settings.proximityDistance) {
                        ForEach(ProximityDistance.allCases) { distance in
                            Text("\(Int(distance.nauticalMiles)) nm").tag(distance)
                        }
                    }
                    Picker("Altitude", selection: $settings.proximityAltitude) {
                        ForEach(ProximityAltitude.allCases) { altitude in
                            Text("\(Int(altitude.feet)) ft").tag(altitude)
                        }
                    }
                }
            } header: {
                sectionHeader("Alerts")
            } footer: {
                Text("Buzzes once per aircraft inside \(Int(settings.proximityDistance.nauticalMiles)) nm below \(Int(settings.proximityAltitude.feet)) ft. Pinned aircraft alert from twice the distance.")
                    .font(Typography.smallLabel)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data from airplanes.live")
                        .font(Typography.label)
                        .foregroundStyle(Palette.dataCyan)
                    Text("Community-fed ADS-B and MLAT. Non-commercial use only, no SLA. Coverage is uneven — an empty sky often means no receiver nearby rather than no aircraft.")
                        .font(Typography.smallLabel)
                        .foregroundStyle(Palette.primaryWhite.opacity(0.7))
                    Link("airplanes.live", destination: URL(string: "https://airplanes.live")!)
                        .font(Typography.smallLabel)
                        .tint(Palette.dataCyan)
                }
                .padding(.vertical, 2)
            } header: {
                sectionHeader("Data")
            }
        }
        .tint(Palette.dataCyan)
        .listRowBackground(Color.clear)
        .containerBackground(Palette.scopeBase, for: .navigation)
        .navigationTitle {
            Text("Settings").foregroundStyle(Palette.dataCyan)
        }
        .onChange(of: settings.radius) { _, _ in
            store.refreshAfterSettling()
        }
        .onChange(of: settings.showsMilitaryOnly) { _, _ in
            Task { await store.refresh() }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typography.sectionHeader)
            .foregroundStyle(Palette.dataCyan.opacity(0.8))
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsView()
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
    }
}
