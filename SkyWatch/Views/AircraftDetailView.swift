import MapKit
import SwiftUI

/// Everything the feed knows about one aircraft, grouped the way a pilot would ask for it.
///
/// Absent fields do not appear. A screen of "—" placeholders would be twice as long and half as
/// informative.
struct AircraftDetailView: View {
    /// FlightAware's `fa_flight_id`.
    let id: String

    @Environment(ScanStore.self) private var store
    @Environment(FlightTrackStore.self) private var flightStore
    @Environment(\.requestTrackTab) private var requestTrackTab
    private var settings: SettingsStore { store.settings }

    private var target: TrackedTarget? {
        store.targets.first { $0.id == id }
    }

    private var aircraft: Aircraft? { target?.aircraft }

    /// Origin → destination, which this feed returns with the scan itself.
    private var route: String? { aircraft?.routeSummary }

    var body: some View {
        ScrollView {
            if let aircraft, let target {
                VStack(alignment: .leading, spacing: 10) {
                    header(aircraft)
                    if let callsign = aircraft.callsign,
                       let flightNumber = FlightNumber.parse(callsign) {
                        trackButton(flightNumber: flightNumber)
                    }
                    map(target)
                    identity(aircraft)
                    routeSection
                    position(target, aircraft)
                    motion(aircraft)
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
        .toolbar {
            if let aircraft {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareText(for: aircraft))
                }
            }
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
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Palette.dataCyan.opacity(0.35), lineWidth: 0.75)
        )
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
            DetailRow("ICAO ident", aircraft.identICAO)
            DetailRow("IATA ident", aircraft.identIATA)
            DetailRow("Type", aircraft.typeCode)
            if let prefix = aircraft.identPrefixLabel {
                DetailRow("Class", prefix, tint: Palette.dataCyan)
            }
        }
    }

    /// Start tracking this aircraft's flight number in the Track tab (with
    /// alerts at 30/15/landed). Only offered when the callsign parses as a
    /// flight number.
    private func trackButton(flightNumber: FlightNumber) -> some View {
        Button {
            flightStore.startTracking(number: flightNumber)
            Haptics.flightMilestone()
            requestTrackTab()
        } label: {
            Label("Track this flight", systemImage: "location.fill")
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(Palette.dataCyan)
    }

    /// Origin → destination. Arrives with the scan on this feed, so there is nothing to load.
    @ViewBuilder
    private var routeSection: some View {
        if let route {
            DetailSection("Route") {
                DetailRow("Route", route, tint: Palette.dataCyan)
                DetailRow("From", aircraft?.origin?.name ?? aircraft?.origin?.city)
                DetailRow("To", aircraft?.destination?.name ?? aircraft?.destination?.city)
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
            switch aircraft.verticalTrend {
            case .climbing:
                DetailRow("Trend", "Climbing", tint: Palette.dataCyan)
            case .descending:
                DetailRow("Trend", "Descending", tint: Palette.cautionAmber)
            case .level:
                DetailRow("Trend", "Level")
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
            if let heading = aircraft.track {
                DetailRow("Heading", Units.bearing(heading).combined)
            }
        }
    }

    private func signal(_ aircraft: Aircraft, target: TrackedTarget) -> some View {
        DetailSection("Signal") {
            DetailRow("Source", aircraft.sourceLabel, tint: target.position.source.isPrecise ? nil : Palette.cautionAmber)
            if let age = target.position.ageSeconds {
                DetailRow("Last position", Units.age(seconds: age), tint: age >= 60 ? Palette.cautionAmber : nil)
            }
        }
    }

    /// A compact one-line summary for the share sheet: "MAS123 · KUL → SYD ·
    /// 4.2 nm · 12,000 ft — SkyWatch".
    private func shareText(for aircraft: Aircraft) -> String {
        var parts = [aircraft.displayName]
        if let route {
            parts.append(route)
        }
        if let target {
            parts.append(Units.distance(nauticalMiles: target.distanceNM, system: settings.unitSystem).combined)
            if let altitude = aircraft.altBaro {
                parts.append(Units.altitude(altitude, system: settings.unitSystem).combined)
            }
        }
        return parts.joined(separator: " · ") + " — SkyWatch"
    }
}

// MARK: - Rows

/// A labelled group rendered as a glass card. Renders nothing at all when
/// every row inside it is absent.
private struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.dataCyan.opacity(0.8))
                .padding(.leading, 2)
            GlassCard(cornerRadius: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    content
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        AircraftDetailView(id: PreviewData.airliner.id)
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
            .environment(FlightTrackStore())
            .environment(\.requestTrackTab) {}
    }
}

#Preview("Lifeguard") {
    NavigationStack {
        AircraftDetailView(id: PreviewData.lifeguard.id)
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
            .environment(FlightTrackStore())
            .environment(\.requestTrackTab) {}
    }
}

#Preview("Gone") {
    NavigationStack {
        AircraftDetailView(id: "nosuchflight")
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
            .environment(FlightTrackStore())
            .environment(\.requestTrackTab) {}
    }
}
