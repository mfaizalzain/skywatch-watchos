import MapKit
import SwiftUI

/// Everything the feed knows about one aircraft, grouped the way a pilot would ask for it.
///
/// Absent fields do not appear. A screen of "—" placeholders would be twice as long and half as
/// informative.
struct AircraftDetailView: View {
    let hex: String

    @Environment(ScanStore.self) private var store
    @State private var refreshedAircraft: Aircraft?

    private var settings: SettingsStore { store.settings }

    /// Prefer the detail-endpoint result, fall back to whatever the last scan had.
    private var target: TrackedTarget? {
        store.targets.first { $0.id == hex }
    }

    private var aircraft: Aircraft? {
        refreshedAircraft ?? target?.aircraft
    }

    var body: some View {
        ScrollView {
            if let aircraft, let target {
                VStack(alignment: .leading, spacing: 10) {
                    header(aircraft)
                    map(target)
                    identity(aircraft)
                    position(target, aircraft)
                    motion(aircraft)
                    status(aircraft)
                    signal(aircraft, target: target)
                }
                .padding(.horizontal, 4)
            } else {
                // The target left range while the screen was open.
                Text("This aircraft is no longer in range.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.cautionAmber)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .containerBackground(Palette.scopeBase, for: .navigation)
        .navigationTitle {
            Text(aircraft?.displayName ?? "Aircraft")
                .foregroundStyle(Palette.targetMagenta)
        }
        .task(id: hex) {
            await pollDetail()
        }
    }

    // MARK: - Sections

    private func header(_ aircraft: Aircraft) -> some View {
        HStack {
            Text(aircraft.displayName)
                .callsignStyle(Typography.primaryValue)
                .foregroundStyle(Palette.targetMagenta)
            Spacer()
            if let target {
                TargetBadges(target: target)
            }
        }
    }

    /// Small on purpose: the numbers are the point, the map is orientation.
    private func map(_ target: TrackedTarget) -> some View {
        let aircraftCoordinate = target.position.coordinate.clCoordinate
        let observer = store.observerCoordinate

        return Map(initialPosition: .region(region(for: target))) {
            if let observer {
                Annotation("You", coordinate: observer.clCoordinate) {
                    Circle()
                        .fill(Palette.dataCyan)
                        .frame(width: 6, height: 6)
                }
                MapPolyline(coordinates: [observer.clCoordinate, aircraftCoordinate])
                    .stroke(Palette.dataCyan.opacity(0.6), lineWidth: 1)
            }
            Annotation(target.aircraft.displayName, coordinate: aircraftCoordinate) {
                Image(systemName: "airplane")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.targetMagenta)
                    .rotationEffect(.degrees((target.aircraft.track ?? 0) - 90))
            }
        }
        .frame(height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func region(for target: TrackedTarget) -> MKCoordinateRegion {
        let observer = store.observerCoordinate ?? target.position.coordinate
        let centre = CLLocationCoordinate2D(
            latitude: (observer.latitude + target.position.coordinate.latitude) / 2,
            longitude: (observer.longitude + target.position.coordinate.longitude) / 2
        )
        // 60 % headroom so neither end sits on the edge of the frame.
        let latitudeSpan = abs(observer.latitude - target.position.coordinate.latitude) * 1.6
        let longitudeSpan = abs(observer.longitude - target.position.coordinate.longitude) * 1.6
        return MKCoordinateRegion(
            center: centre,
            span: MKCoordinateSpan(
                latitudeDelta: max(latitudeSpan, 0.05),
                longitudeDelta: max(longitudeSpan, 0.05)
            )
        )
    }

    private func identity(_ aircraft: Aircraft) -> some View {
        DetailSection("Identity") {
            DetailRow("Callsign", aircraft.callsign)
            DetailRow("Registration", aircraft.registration)
            DetailRow("Type", aircraft.typeCode)
            DetailRow("Category", aircraft.category)
            DetailRow("Hex", aircraft.displayHex?.uppercased())
            if aircraft.isNonICAOAddress {
                DetailRow("Address", "Non-ICAO", tint: Palette.cautionAmber)
            }
            if aircraft.flags.contains(.military) {
                DetailRow("Operator", "Military", tint: Palette.dataCyan)
            }
            if aircraft.flags.contains(.interesting) {
                DetailRow("Operator", "Interesting", tint: Palette.dataCyan)
            }
            if aircraft.flags.contains(.pia) {
                DetailRow("Privacy", "PIA address", tint: Palette.cautionAmber)
            }
            if aircraft.flags.contains(.ladd) {
                DetailRow("Privacy", "LADD", tint: Palette.cautionAmber)
            }
        }
    }

    private func position(_ target: TrackedTarget, _ aircraft: Aircraft) -> some View {
        DetailSection("Position") {
            DetailRow("Distance", Units.distance(nauticalMiles: target.distanceNM, system: settings.unitSystem).combined)
            DetailRow("Bearing", Units.bearing(target.bearingDegrees).combined)
            if let altitude = aircraft.altBaro {
                DetailRow("Altitude", Units.altitude(altitude, system: settings.unitSystem).combined)
            }
            if let geometric = aircraft.altGeom {
                DetailRow("Geometric", Units.altitude(feet: geometric, system: settings.unitSystem).combined)
            }
            if let rate = aircraft.baroRate ?? aircraft.geomRate {
                DetailRow(
                    "Vertical rate",
                    Units.verticalRate(feetPerMinute: rate, system: settings.unitSystem).combined,
                    tint: rate > 64 ? Palette.dataCyan : (rate < -64 ? Palette.cautionAmber : nil)
                )
            }
            if let approach = target.closestApproach, approach.timeToClosestApproach > 0 {
                DetailRow(
                    "Closest in",
                    "\(Units.age(seconds: approach.timeToClosestApproach)) · \(Units.distance(nauticalMiles: approach.minimumDistanceNM, system: settings.unitSystem).combined)"
                )
            }
        }
    }

    private func motion(_ aircraft: Aircraft) -> some View {
        DetailSection("Motion") {
            if let speed = aircraft.groundSpeed {
                DetailRow("Ground speed", Units.speed(knots: speed, system: settings.unitSystem).combined)
            }
            if let ias = aircraft.indicatedAirspeed {
                DetailRow("IAS", Units.speed(knots: ias, system: settings.unitSystem).combined)
            }
            if let tas = aircraft.trueAirspeed {
                DetailRow("TAS", Units.speed(knots: tas, system: settings.unitSystem).combined)
            }
            if let mach = aircraft.mach {
                DetailRow("Mach", String(format: "%.2f", mach))
            }
            if let track = aircraft.track {
                DetailRow("Track", Units.bearing(track).combined)
            }
            if let heading = aircraft.trueHeading ?? aircraft.magHeading {
                DetailRow("Heading", Units.bearing(heading).combined)
            }
            if let roll = aircraft.roll {
                DetailRow("Roll", String(format: "%.0f°", roll))
            }
            if !aircraft.navModeList.isEmpty {
                DetailRow("Nav modes", aircraft.navModeList.joined(separator: " "))
            }
            if let selected = aircraft.navAltitudeMCP {
                DetailRow("Selected alt", Units.altitude(feet: selected, system: settings.unitSystem).combined)
            }
        }
    }

    private func status(_ aircraft: Aircraft) -> some View {
        DetailSection("Status") {
            if let squawk = aircraft.squawk {
                DetailRow("Squawk", squawk, tint: aircraft.hasEmergencySquawk ? Palette.warningRed : nil)
            }
            if aircraft.emergency.isActive {
                DetailRow("Emergency", aircraft.emergency.label, tint: Palette.warningRed)
            }
            if aircraft.alert == 1 {
                DetailRow("Alert", "Active", tint: Palette.warningRed)
            }
            if aircraft.spi == 1 {
                DetailRow("Ident", "Active", tint: Palette.dataCyan)
            }
            if let direction = aircraft.windDirection, let speed = aircraft.windSpeed {
                DetailRow("Wind", "\(Units.bearing(direction).combined) · \(Units.speed(knots: speed, system: settings.unitSystem).combined)")
            }
            if let oat = aircraft.outsideAirTemperature {
                DetailRow("OAT", Units.temperature(celsius: oat).combined)
            }
            if let qnh = aircraft.navQNH {
                DetailRow("QNH", String(format: "%.1f hPa", qnh))
            }
        }
    }

    private func signal(_ aircraft: Aircraft, target: TrackedTarget) -> some View {
        DetailSection("Signal") {
            DetailRow("Source", sourceLabel(aircraft), tint: target.position.source.isPrecise ? nil : Palette.cautionAmber)
            if let seen = aircraft.seen {
                DetailRow("Last message", Units.age(seconds: seen))
            }
            if let seenPos = aircraft.seenPos {
                DetailRow("Last position", Units.age(seconds: seenPos), tint: seenPos >= 60 ? Palette.cautionAmber : nil)
            }
            if let rssi = aircraft.rssi {
                DetailRow("RSSI", String(format: "%.1f dBFS", rssi))
            }
            if let nic = aircraft.nic {
                DetailRow("NIC", "\(nic)")
            }
            if let rc = aircraft.rc {
                DetailRow("Radius of containment", "\(rc) m")
            }
            if let version = aircraft.version {
                DetailRow("ADS-B version", "\(version)")
            }
        }
    }

    private func sourceLabel(_ aircraft: Aircraft) -> String {
        switch aircraft.sourceType ?? "" {
        case "adsb_icao", "adsb_icao_nt": "ADS-B"
        case "adsr_icao": "ADS-R"
        case "tisb_icao", "tisb_trackfile", "tisb_other": "TIS-B"
        case "mlat": "MLAT"
        case "adsc": "ADS-C"
        case "mode_s": "Mode S"
        case "": "Unknown"
        case let other: other.uppercased()
        }
    }

    // MARK: - Detail refresh

    /// Half the scan cadence, through the same rate limiter as everything else. The scan loop is
    /// still running behind this screen, so anything faster would be two requests fighting for the
    /// same 1.2 s slot.
    private func pollDetail() async {
        while !Task.isCancelled {
            if let updated = await store.refreshDetail(hex: hex) {
                refreshedAircraft = updated
            }
            let interval = store.settings.refreshInterval.seconds * 2
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}

// MARK: - Rows

/// A labelled group. Renders nothing at all when every row inside it is absent.
private struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.dataCyan.opacity(0.8))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One label/value pair. A nil value means the row does not exist.
private struct DetailRow: View {
    let label: String
    let value: String?
    var tint: Color?

    init(_ label: String, _ value: String?, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(Typography.smallLabel)
                    .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                Spacer(minLength: 6)
                Text(value)
                    .font(Typography.smallValue)
                    .foregroundStyle(tint ?? Palette.primaryWhite)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Previews

#Preview("Airliner") {
    NavigationStack {
        AircraftDetailView(hex: PreviewData.airliner.hex ?? "")
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
    }
}

#Preview("Emergency") {
    NavigationStack {
        AircraftDetailView(hex: PreviewData.emergency.hex ?? "")
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
    }
}

#Preview("Gone") {
    NavigationStack {
        AircraftDetailView(hex: "nosuchhex")
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
    }
}
