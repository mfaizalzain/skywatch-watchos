import SwiftUI

struct SettingsView: View {
    @Environment(ScanStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings

        List {
            Section("Scan") {
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
            }

            Section("Scope") {
                Toggle("Heading up", isOn: $settings.isHeadingUp)
                Toggle("Hide ground traffic", isOn: $settings.hidesGroundTraffic)
                Toggle("Military only", isOn: $settings.showsMilitaryOnly)
                Toggle("Include MLAT & estimated", isOn: $settings.includesUncertainTargets)
            }

            Section {
                Toggle("Proximity haptic", isOn: $settings.hapticAlertsEnabled)
            } footer: {
                Text("Buzzes once per aircraft when one comes inside 3 nm below 8,000 ft.")
                    .font(Typography.smallLabel)
            }

            Section("Data") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data from airplanes.live")
                        .font(Typography.label)
                        .foregroundStyle(Palette.dataCyan)
                    Text("Community-fed ADS-B and MLAT. Non-commercial use only, no SLA. Coverage is uneven — an empty sky often means no receiver nearby rather than no aircraft.")
                        .font(Typography.smallLabel)
                        .foregroundStyle(Palette.primaryWhite.opacity(0.7))
                    Link("airplanes.live", destination: URL(string: "https://airplanes.live")!)
                        .font(Typography.smallLabel)
                }
                .padding(.vertical, 2)
            }
        }
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
}

#Preview("Settings") {
    NavigationStack {
        SettingsView()
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
    }
}
