import SwiftUI

/// Track Flight: enter a flight number, pick the arrival airport, and get
/// alerts at 30 min / 15 min / landed.
struct TrackFlightView: View {
    @Environment(FlightTrackStore.self) private var store

    @State private var flightNumberText = ""
    @State private var selectedAirport: Airport?
    @State private var pickerPresented = false
    @State private var parseError = false

    var body: some View {
        Group {
            if store.flightNumber == nil {
                setupForm
            } else {
                trackingCard
            }
        }
        // Attached at the Group level, not to setupForm: the tracking card's
        // "Choose Airport" fallback (when FlightAware can't resolve the
        // destination) needs the same picker.
        .sheet(isPresented: $pickerPresented) {
            airportPicker
        }
        .navigationTitle("Track Flight")
    }

    // MARK: - Setup

    private var setupForm: some View {
        VStack(spacing: 10) {
            TextField("Flight number (e.g. MH123)", text: $flightNumberText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 6)

            Button {
                pickerPresented = true
            } label: {
                HStack {
                    Text(selectedAirport.map { "\($0.iata) · \($0.city)" } ?? "Arrival airport: Auto (FlightAware)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.scopeBase.opacity(0.45)))
            }
            .buttonStyle(.plain)

            if parseError {
                Text("Enter a flight number like MH123 or MAS123")
                    .font(.caption2)
                    .foregroundStyle(Palette.cautionAmber)
            }

            Button {
                startTracking()
            } label: {
                Label("Start Tracking", systemImage: "airplane.departure")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(flightNumberText.trimmed.isEmpty)
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
    }

    private var airportPicker: some View {
        NavigationStack {
            List(Airport.common) { airport in
                Button {
                    if store.flightNumber == nil {
                        selectedAirport = airport
                    } else {
                        store.selectAirport(airport)
                    }
                    pickerPresented = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(airport.city)
                                .font(.system(.body, design: .rounded).weight(.medium))
                            Text("\(airport.iata) · \(airport.name)")
                                .font(.caption2)
                                .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                        }
                        Spacer()
                        let current = store.airport ?? selectedAirport
                        if current == airport {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Palette.dataCyan)
                        }
                    }
                }
            }
            .navigationTitle("Arrival Airport")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pickerPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func startTracking() {
        guard let parsed = FlightNumber.parse(flightNumberText) else {
            parseError = true
            return
        }
        parseError = false
        // Airport is optional: nil means "auto-detect from FlightAware".
        store.startTracking(number: parsed, airport: selectedAirport)
    }

    // MARK: - Tracking

    private var trackingCard: some View {
        ScrollView {
            VStack(spacing: 10) {
                headerRow
                statusCard
                officialStatus
                alertMilestones
                stopButton
            }
            .padding(.horizontal, 12)
        }
        // Permission can change while tracking (enabled in the Watch app's
        // settings) — re-read it so the hint reflects reality.
        .task { await store.refreshNotificationPermission() }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(store.flightNumber?.callsign ?? "—")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    liveBadge
                }
                if let airport = store.airport {
                    Text("arriving \(airport.iata) · \(airport.city)")
                        .font(.caption)
                        .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                }
            }
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// Green dot + label when the flight is transmitting a live position.
    @ViewBuilder
    private var liveBadge: some View {
        if store.phase.isLive {
            HStack(spacing: 3) {
                Circle()
                    .fill(Palette.successGreen)
                    .frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.successGreen)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.successGreen.opacity(0.15)))
        } else if store.phase != .idle {
            Text("NOT LIVE")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.primaryWhite.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Palette.primaryWhite.opacity(0.12)))
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 6) {
            switch store.phase {
            case .idle:
                EmptyView()
            case .searching:
                if store.airport == nil {
                    // FlightAware couldn't resolve the destination (no key in
                    // the build, or it isn't in the catalog) — the picker is
                    // the fallback to start measuring distance/ETA.
                    statusRow(icon: "magnifyingglass", title: "Choose arrival airport",
                              detail: "FlightAware didn't recognise it — pick the destination to start ETA")
                    Button {
                        pickerPresented = true
                    } label: {
                        Label("Choose Airport", systemImage: "mappin.and.ellipse")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                } else {
                    statusRow(icon: "magnifyingglass", title: "Searching for flight…",
                              detail: "Waiting for the aircraft to appear in the feed")
                }
            case let .inAir(eta):
                if let eta {
                    Text(etaText(eta))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("to landing")
                        .font(.caption)
                        .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                } else {
                    statusRow(icon: "airplane", title: "In the air",
                              detail: "Position known; ETA needs ground speed")
                }
                if let distanceNM = store.distanceNM, distanceNM.isFinite {
                    Text("\(Int(distanceNM.rounded())) NM from \(store.airport?.iata ?? "airport")")
                        .font(.caption2)
                        .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                }
            case let .onGround(distance):
                statusRow(icon: "airplane.arrival", title: "On the ground",
                          detail: distanceText(distance))
            case .disappeared:
                statusRow(icon: "checkmark.seal.fill", title: "Landed",
                          detail: "Aircraft powered down near the airport")
            case .notFound:
                statusRow(icon: "questionmark.circle", title: "Not live right now",
                          detail: "Flight not in the feed — not departed, out of coverage, or already landed")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassCardBackground(cornerRadius: 14)
    }

    /// Official status from FlightAware (when the AeroAPI layer is active).
    @ViewBuilder
    private var officialStatus: some View {
        if store.aeroStatus != nil || store.aeroError != nil {
            VStack(spacing: 4) {
                if let aeroError = store.aeroError {
                    Label(aeroError, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Palette.cautionAmber)
                } else if let status = store.aeroStatus {
                    HStack(spacing: 4) {
                        Image(systemName: officialIcon(status))
                            .foregroundStyle(officialColor(status))
                        Text(officialTitle(status))
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                        Spacer()
                    }
                    if let route = store.route {
                        Text(route)
                            .font(.system(.caption2, design: .monospaced).weight(.medium))
                            .foregroundStyle(Palette.primaryWhite.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let gate = store.gate {
                        Text("Gate \(gate)\(store.terminal.map { " · Terminal \($0)" } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let arrival = store.officialArrival {
                        Text("Arrives \(arrival.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .glassCardBackground(cornerRadius: 12)
        }
    }

    private func officialIcon(_ status: AeroStatus) -> String {
        switch status {
        case .landed, .arrived: "checkmark.seal.fill"
        case .enRoute: "airplane"
        case .departed: "airplane.departure"
        case .cancelled: "xmark.octagon"
        case .diverted: "arrow.triangle.branch"
        default: "calendar"
        }
    }

    private func officialColor(_ status: AeroStatus) -> Color {
        switch status {
        case .landed, .arrived: Palette.successGreen
        case .cancelled, .diverted: Palette.warningRed
        default: Palette.dataCyan
        }
    }

    private func officialTitle(_ status: AeroStatus) -> String {
        switch status {
        case .scheduled: "Scheduled"
        case .departed: "Departed"
        case .enRoute: "En route"
        case .landed: "Landed"
        case .arrived: "Arrived"
        case .cancelled: "Cancelled"
        case .diverted: "Diverted"
        case .unknown: "Status unknown"
        }
    }

    private var alertMilestones: some View {
        VStack(spacing: 4) {
            milestoneRow(title: "30 min to landing", fired: store.alertState.hasFired30)
            milestoneRow(title: "15 min to landing", fired: store.alertState.hasFired15)
            milestoneRow(title: "Landed", fired: store.alertState.hasFiredLanded)
            if store.notificationPermission == .denied {
                Label("Notifications are off — alerts won't fire while the watch screen is off. Enable them for this app in the Watch app's notification settings.", systemImage: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(Palette.cautionAmber)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .glassCardBackground(cornerRadius: 12)
    }

    private var stopButton: some View {
        VStack(spacing: 6) {
            if store.hasAutoStopped {
                Label("Tracking stopped after landing", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Palette.successGreen)
            }
            Button(role: .destructive) {
                store.stopTracking()
            } label: {
                Label("Stop Tracking", systemImage: "stop.circle")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Row helpers

    private func statusRow(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Palette.dataCyan)
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Palette.primaryWhite)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Palette.primaryWhite.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private func milestoneRow(title: String, fired: Bool) -> some View {
        HStack {
            Image(systemName: fired ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(fired ? Palette.successGreen : Palette.primaryWhite.opacity(0.35))
                .font(.caption)
            Text(title)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(fired ? Palette.primaryWhite : Palette.primaryWhite.opacity(0.55))
            Spacer()
            Text(fired ? "alert sent" : "waiting")
                .font(.caption2)
                .foregroundStyle(fired ? Palette.successGreen : Palette.primaryWhite.opacity(0.35))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private func etaText(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded(.down))
        if rounded >= 60 {
            return "\(rounded / 60)h \(String(format: "%02d", rounded % 60))m"
        }
        return "\(rounded)m"
    }

    private func distanceText(_ distance: Double?) -> String {
        guard let distance, distance.isFinite else {
            return "Position unknown"
        }
        return distance <= FlightTracker.landedDistanceNM
            ? "At the airport"
            : "\(Int(distance.rounded())) NM from airport"
    }
}

#Preview("Track Flight") {
    TrackFlightView()
        .environment(FlightTrackStore())
}
