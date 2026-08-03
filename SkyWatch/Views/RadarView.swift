import SwiftUI

/// The scope. Centre is you; blips are aircraft, rotated to their track so you can see where each
/// one is going rather than only where it is.
struct RadarView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var crownPosition: Double = 0
    @State private var hasSyncedCrown = false

    private var settings: SettingsStore { store.settings }

    /// Heading-up only when we asked for it *and* the compass is actually giving us something.
    /// Falling back to north-up silently is better than a scope that points nowhere in particular.
    private var deviceHeading: Double? {
        guard settings.isHeadingUp, let heading = store.location.heading else { return nil }
        return heading
    }

    private var targets: [TrackedTarget] { store.visibleTargets }

    private var failure: FailureState? {
        if let error = FailureState(error: store.error, dataAge: store.dataAge) { return error }
        if store.observerCoordinate == nil { return .awaitingLocation }
        if targets.isEmpty, store.hasEverLoaded { return .noAircraft(radius: settings.radius) }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ScopeGeometry(
                size: proxy.size,
                rangeNM: settings.radius.nauticalMiles,
                rotation: deviceHeading ?? 0
            )

            ZStack {
                Palette.scopeBase

                ScopeCanvas(
                    geometry: geometry,
                    targets: targets,
                    nearestID: store.nearest?.id,
                    pinned: settings.pinnedHexes,
                    observer: store.observerCoordinate,
                    unitSystem: settings.unitSystem,
                    isLuminanceReduced: isLuminanceReduced
                )

                SweepLine(
                    geometry: geometry,
                    headingDegrees: store.location.heading,
                    isStatic: reduceMotion || isLuminanceReduced
                )

                // The canvas can't be tapped and can't be read aloud, so the interaction layer is
                // made of real views sitting on top of it.
                blipTargets(geometry: geometry)

                if let failure {
                    FailureStateView(
                        state: failure,
                        onWiden: { widen(to: $0) },
                        onRetry: { Task { await store.refresh() } }
                    )
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(isLuminanceReduced ? 0 : 0.7))
                            .padding(-8)
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { calloutOverlay }
        .overlay(alignment: .top) { statusOverlay }
        .focusable()
        .digitalCrownRotation(
            $crownPosition,
            from: 0,
            through: Double(ScanRadius.allCases.count - 1),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            // Haptics are played per *detent* below rather than per tick, so the crown feels like
            // it has four stops rather than a continuous rasp.
            isHapticFeedbackEnabled: false
        )
        .onChange(of: crownPosition) { _, newValue in
            crownDidMove(to: newValue)
        }
        .onAppear {
            syncCrownToSettings()
            if settings.isHeadingUp { store.location.startUpdatingHeading() }
        }
        .onDisappear {
            // The compass is expensive; it runs only while the scope is on screen.
            store.location.stopUpdatingHeading()
        }
        .onChange(of: settings.isHeadingUp) { _, headingUp in
            headingUp ? store.location.startUpdatingHeading() : store.location.stopUpdatingHeading()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Radar scope")
        .accessibilityValue(scopeAccessibilityValue)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var calloutOverlay: some View {
        if failure == nil, let nearest = store.nearest {
            NearestCallout(
                target: nearest,
                unitSystem: settings.unitSystem,
                deviceHeading: deviceHeading
            )
            .padding(.bottom, 2)
        }
    }

    /// Two things worth knowing at a glance and nothing else: that the position is approximate, and
    /// that the data on screen is older than it looks.
    @ViewBuilder
    private var statusOverlay: some View {
        HStack(spacing: 4) {
            if store.location.hasReducedAccuracy {
                Badge(text: "APPROX", color: Palette.cautionAmber, isLuminanceReduced: isLuminanceReduced)
                    .accessibilityLabel("Approximate location. Consider a wider radius.")
            }
            if store.error != nil, let age = store.dataAge, age > 30 {
                Badge(text: Units.age(seconds: age), color: Palette.cautionAmber, isLuminanceReduced: isLuminanceReduced)
                    .accessibilityLabel("Data is \(Units.age(seconds: age)) old")
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Hit targets

    /// Blips are drawn small, but every one carries a 28 pt tap area — the glyph is the readout,
    /// the invisible square is the control.
    @ViewBuilder
    private func blipTargets(geometry: ScopeGeometry) -> some View {
        ForEach(targets) { target in
            let point = geometry.point(
                bearingDegrees: target.bearingDegrees,
                distanceNM: target.distanceNM
            )

            NavigationLink(value: target.id) {
                Color.clear
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(point)
            .accessibilityLabel(target.accessibilityDescription(unitSystem: settings.unitSystem))
        }
    }

    private var scopeAccessibilityValue: String {
        guard !targets.isEmpty else {
            return "No aircraft within \(Int(settings.radius.nauticalMiles)) nautical miles"
        }
        let orientation = deviceHeading == nil ? "north up" : "heading up"
        return "\(targets.count) aircraft within \(Int(settings.radius.nauticalMiles)) nautical miles, \(orientation)"
    }

    // MARK: - Crown

    private func syncCrownToSettings() {
        guard !hasSyncedCrown else { return }
        hasSyncedCrown = true
        if let index = ScanRadius.allCases.firstIndex(of: settings.radius) {
            crownPosition = Double(index)
        }
    }

    private func crownDidMove(to value: Double) {
        guard hasSyncedCrown else { return }
        let index = min(max(Int(value.rounded()), 0), ScanRadius.allCases.count - 1)
        let radius = ScanRadius.allCases[index]
        guard radius != settings.radius else { return }

        settings.radius = radius
        Haptics.crownDetent()
        // One request when the crown stops, not one per detent — four fast clicks would otherwise
        // be four requests.
        store.refreshAfterSettling()
    }

    private func widen(to radius: ScanRadius) {
        settings.radius = radius
        if let index = ScanRadius.allCases.firstIndex(of: radius) {
            crownPosition = Double(index)
        }
        Task { await store.refresh() }
    }
}

// MARK: - Scope canvas

/// Rings, trails and blips in a single draw pass. Thirty-plus targets as individual SwiftUI views
/// costs noticeably more on a 40 mm display than one `Canvas` does.
private struct ScopeCanvas: View {
    let geometry: ScopeGeometry
    let targets: [TrackedTarget]
    let nearestID: TrackedTarget.ID?
    let pinned: Set<String>
    let observer: Coordinate?
    let unitSystem: UnitSystem
    let isLuminanceReduced: Bool

    var body: some View {
        Canvas { context, _ in
            drawRings(in: context)
            // Always-On drops to the minimum that still answers "is anything up there?"
            if !isLuminanceReduced {
                for target in targets { drawTrail(for: target, in: context) }
            }
            for target in targets { drawBlip(for: target, in: context) }
            drawCentre(in: context)
        }
        .accessibilityHidden(true)
    }

    private var ringColor: Color {
        Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced).opacity(0.45)
    }

    private func drawRings(in context: GraphicsContext) {
        for fraction in geometry.ringFractions {
            let radius = geometry.ringRadius(fraction)
            let rect = CGRect(
                x: geometry.center.x - radius,
                y: geometry.center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(ringColor),
                lineWidth: fraction == 1.0 ? 1.0 : 0.5
            )

            // Ring labels sit low-left, out of the way of the nearest-target callout.
            let value = Units.distance(nauticalMiles: geometry.rangeNM * fraction, system: unitSystem)
            var label = context.resolve(Text(value.value).font(Typography.smallValue))
            label.shading = .color(ringColor)
            let angle = Double(225).radians
            context.draw(
                label,
                at: CGPoint(
                    x: geometry.center.x + radius * CGFloat(sin(angle)),
                    y: geometry.center.y - radius * CGFloat(cos(angle))
                )
            )
        }
    }

    /// Two or three previous positions, fading out. This is the one piece of ornament that earns
    /// its place: it turns a dot into a direction of travel.
    private func drawTrail(for target: TrackedTarget, in context: GraphicsContext) {
        guard !target.trail.isEmpty, let observer else { return }

        let color = Palette.target(
            target,
            isSelected: target.id == nearestID,
            isPinned: pinned.contains(target.id)
        )

        for (index, point) in target.trail.enumerated() {
            let distance = Geodesy.distanceNM(from: observer, to: point.coordinate)
            let bearing = Geodesy.initialBearing(from: observer, to: point.coordinate)
            let position = geometry.point(bearingDegrees: bearing, distanceNM: distance)
            // Oldest sample is faintest.
            let opacity = 0.15 + 0.2 * (Double(index + 1) / Double(target.trail.count))
            let dot = Path(ellipseIn: CGRect(x: position.x - 1, y: position.y - 1, width: 2, height: 2))
            context.fill(dot, with: .color(color.opacity(opacity)))
        }
    }

    private func drawBlip(for target: TrackedTarget, in context: GraphicsContext) {
        let position = geometry.point(
            bearingDegrees: target.bearingDegrees,
            distanceNM: target.distanceNM
        )
        let color = Palette.dimmed(
            Palette.target(
                target,
                isSelected: target.id == nearestID,
                isPinned: pinned.contains(target.id)
            ),
            isLuminanceReduced: isLuminanceReduced
        )
        // A target we didn't hear this cycle is drawn faded rather than removed — one dropped
        // position report at the edge of coverage is routine.
        let opacity = target.isFading ? 0.4 : 1.0

        if let track = target.aircraft.track {
            var path = Path()
            let length: CGFloat = 5
            let width: CGFloat = 3.5
            path.move(to: CGPoint(x: 0, y: -length))
            path.addLine(to: CGPoint(x: width, y: length * 0.7))
            path.addLine(to: CGPoint(x: 0, y: length * 0.35))
            path.addLine(to: CGPoint(x: -width, y: length * 0.7))
            path.closeSubpath()

            let transform = CGAffineTransform(translationX: position.x, y: position.y)
                .rotated(by: geometry.glyphRotation(trackDegrees: track).radians)
            context.fill(path.applying(transform), with: .color(color.opacity(opacity)))
        } else {
            // No track: a dot, because a triangle would imply a direction we don't know.
            let dot = Path(ellipseIn: CGRect(x: position.x - 2.5, y: position.y - 2.5, width: 5, height: 5))
            context.fill(dot, with: .color(color.opacity(opacity)))
        }

        // Estimated positions get a ring instead of a solid glyph — visibly not a fix.
        if target.position.source == .estimated {
            let ring = Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10))
            context.stroke(ring, with: .color(color.opacity(0.5)), lineWidth: 0.5)
        }
    }

    private func drawCentre(in context: GraphicsContext) {
        let color = Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced)
        let size: CGFloat = 3
        let rect = CGRect(
            x: geometry.center.x - size / 2,
            y: geometry.center.y - size / 2,
            width: size,
            height: size
        )
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }
}

// MARK: - Sweep

/// Not decoration: the sweep points where the device is facing, so the scope also answers "which
/// way am I looking?". Under Reduce Motion it becomes a static tick with no animation.
private struct SweepLine: View {
    let geometry: ScopeGeometry
    let headingDegrees: Double?
    let isStatic: Bool

    var body: some View {
        // In heading-up mode the scope itself is already rotated, so the sweep sits at the top.
        let angle = Geodesy.normalized0to360((headingDegrees ?? 0) - geometry.rotation)

        Canvas { context, _ in
            let radians = angle.radians
            let tip = CGPoint(
                x: geometry.center.x + geometry.radius * CGFloat(sin(radians)),
                y: geometry.center.y - geometry.radius * CGFloat(cos(radians))
            )

            var path = Path()
            path.move(to: geometry.center)
            path.addLine(to: tip)

            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [Palette.dataCyan.opacity(0.05), Palette.dataCyan.opacity(0.7)]),
                    startPoint: geometry.center,
                    endPoint: tip
                ),
                lineWidth: 1
            )
        }
        .opacity(headingDegrees == nil ? 0 : 1)
        .animation(isStatic ? nil : .easeOut(duration: 0.35), value: angle)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Dense") {
    RadarPreview(targets: PreviewData.dense)
}

#Preview("One target") {
    RadarPreview(targets: [PreviewData.airlinerTarget])
}

#Preview("Empty") {
    RadarPreview(targets: [])
}

/// Previews drive the real view through a store seeded with fixtures, so what renders here is what
/// renders on the wrist.
private struct RadarPreview: View {
    let targets: [TrackedTarget]

    var body: some View {
        NavigationStack {
            RadarView()
                .environment(ScanStore.previewStore(targets: targets))
        }
    }
}
