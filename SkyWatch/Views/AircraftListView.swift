import SwiftUI

/// Everything in range, nearest first, two lines per aircraft.
struct AircraftListView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var settings: SettingsStore { store.settings }
    private var targets: [TrackedTarget] { store.visibleTargets }

    private var failure: FailureState? {
        if let error = FailureState(error: store.error, dataAge: store.dataAge) { return error }
        if store.observerCoordinate == nil { return .awaitingLocation }
        if targets.isEmpty, store.hasEverLoaded { return .noAircraft(radius: settings.radius) }
        return nil
    }

    var body: some View {
        List {
            if let failure {
                FailureStateView(
                    state: failure,
                    onWiden: { widen(to: $0) },
                    onRetry: { Task { await store.refresh() } }
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            ForEach(targets) { target in
                NavigationLink(value: target.id) {
                    AircraftRow(
                        target: target,
                        unitSystem: settings.unitSystem,
                        deviceHeading: settings.isHeadingUp ? store.location.heading : nil,
                        isPinned: settings.isPinned(target.id),
                        isLuminanceReduced: isLuminanceReduced
                    )
                }
                .swipeActions(edge: .leading) {
                    Button {
                        settings.togglePin(target.id)
                        Haptics.selectionChanged()
                    } label: {
                        Label(
                            settings.isPinned(target.id) ? "Unpin" : "Pin",
                            systemImage: settings.isPinned(target.id) ? "pin.slash" : "pin"
                        )
                    }
                    .tint(Palette.targetMagenta)
                }
            }

            // Mode S targets are real aircraft we genuinely heard — they just can't be placed, so
            // they are counted rather than drawn.
            if store.positionlessCount > 0 {
                Text("\(store.positionlessCount) heard, no position")
                    .font(Typography.smallLabel)
                    .foregroundStyle(Palette.dataCyan.opacity(0.7))
                    .listRowBackground(Color.clear)
            }

            NavigationLink(value: Route.settings) {
                Label("Settings", systemImage: "gearshape")
                    .font(Typography.label)
            }
        }
        .listStyle(.carousel)
        .containerBackground(Palette.scopeBase, for: .navigation)
        .navigationTitle {
            Text(title)
                .foregroundStyle(Palette.dataCyan)
        }
    }

    private var title: String {
        guard store.hasEverLoaded else { return "SkyWatch" }
        return "\(targets.count) · \(Int(settings.radius.nauticalMiles)) nm"
    }

    private func widen(to radius: ScanRadius) {
        settings.radius = radius
        Task { await store.refresh() }
    }
}

/// One aircraft, two lines, no wasted glance time.
struct AircraftRow: View {
    let target: TrackedTarget
    let unitSystem: UnitSystem
    let deviceHeading: Double?
    var isPinned = false
    var isLuminanceReduced = false

    private var arrowDegrees: Double {
        guard let deviceHeading else { return target.bearingDegrees }
        return Geodesy.relativeBearing(absolute: target.bearingDegrees, deviceHeading: deviceHeading)
    }

    private var accentColor: Color {
        Palette.dimmed(
            Palette.target(target, isPinned: isPinned),
            isLuminanceReduced: isLuminanceReduced
        )
    }

    private var valueColor: Color {
        Palette.dimmed(Palette.primaryWhite, isLuminanceReduced: isLuminanceReduced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.targetMagenta)
                        .accessibilityHidden(true)
                }

                Text(target.aircraft.displayName)
                    .callsignStyle()
                    .foregroundStyle(accentColor)

                Spacer(minLength: 2)

                TargetBadges(target: target, isLuminanceReduced: isLuminanceReduced)
            }

            HStack(spacing: 4) {
                BearingArrow(degrees: arrowDegrees, color: accentColor)

                Text(Units.distance(nauticalMiles: target.distanceNM, system: unitSystem).value)
                    .font(Typography.smallValue)
                    .foregroundStyle(valueColor)

                if let altitude = target.aircraft.altBaro {
                    VerticalTrendChevron(
                        trend: target.aircraft.verticalTrend,
                        color: Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced)
                    )
                    Text(Units.altitude(altitude, system: unitSystem).value)
                        .font(Typography.smallValue)
                        .foregroundStyle(valueColor)
                }

                if let speed = target.aircraft.groundSpeed {
                    Text(Units.speed(knots: speed, system: unitSystem).value)
                        .font(Typography.smallValue)
                        .foregroundStyle(Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced))
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.accessibilityDescription(unitSystem: unitSystem))
    }
}

// MARK: - Previews

#Preview("Populated") {
    NavigationStack {
        AircraftListView()
            .environment(ScanStore.previewStore(targets: PreviewData.handful))
    }
}

#Preview("Dense") {
    NavigationStack {
        AircraftListView()
            .environment(ScanStore.previewStore(targets: PreviewData.dense))
    }
}

#Preview("Empty") {
    NavigationStack {
        AircraftListView()
            .environment(ScanStore.previewStore(targets: []))
    }
}

#Preview("Offline") {
    NavigationStack {
        AircraftListView()
            .environment(ScanStore.previewStore(targets: PreviewData.handful, error: .offline))
    }
}
