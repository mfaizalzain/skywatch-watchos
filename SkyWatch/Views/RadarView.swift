import SwiftUI

/// The scope. Centre is you; blips are aircraft, rotated to their track so you can see where each
/// one is going rather than only where it is.
struct RadarView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var crownPosition: Double = 0

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
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) { calloutOverlay }
        .overlay(alignment: .top) { topOverlay }
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
            // The callout is the most obvious thing on the scope — make it the
            // way into the nearest aircraft's detail screen too.
            NavigationLink(value: nearest.id) {
                NearestCallout(
                    target: nearest,
                    unitSystem: settings.unitSystem,
                    deviceHeading: deviceHeading
                )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)
        }
    }

    /// Emergency banner above the status row: an alerting aircraft gets a
    /// red, tappable banner instead of being just another red glyph.
    @ViewBuilder
    private var topOverlay: some View {
        VStack(spacing: 4) {
            if let emergency = store.visibleTargets.first(where: { $0.aircraft.isAlerting }) {
                NavigationLink(value: emergency.id) {
                    EmergencyBanner(target: emergency, isLuminanceReduced: isLuminanceReduced)
                }
                .buttonStyle(.plain)
            }
            statusOverlay
        }
        .padding(.top, 2)
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
            } else if store.error == nil, store.hasEverLoaded,
                      let age = store.dataAge,
                      age > Double(isLuminanceReduced ? 120 : settings.refreshInterval.seconds) {
                // Nothing wrong — just an honest stamp that the scope is on
                // the slow Always-On cadence or a refresh hasn't landed yet.
                Badge(
                    text: Units.age(seconds: age),
                    color: Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced),
                    isLuminanceReduced: isLuminanceReduced
                )
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
        // The crown is the range control: whenever the scope appears — first
        // launch, tab switch, or popping back from Settings after changing the
        // radius there — point it at the current radius.
        guard let index = ScanRadius.allCases.firstIndex(of: settings.radius) else { return }
        let target = Double(index)
        guard crownPosition != target else { return }
        crownPosition = target
    }

    private func crownDidMove(to value: Double) {
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
        Canvas { context, size in
            drawBackdrop(in: context, size: size)
            drawRings(in: context)
            // Always-On drops to the minimum that still answers "is anything up there?"
            if !isLuminanceReduced {
                for target in targets { drawTrail(for: target, in: context) }
            }
            drawBlips(in: context)
            drawCentre(in: context)
        }
        .accessibilityHidden(true)
    }

    /// A soft centre glow over true black: the scope reads as lit glass rather
    /// than a flat disc. Skipped on Always-On so the OLED stays mostly off.
    private func drawBackdrop(in context: GraphicsContext, size: CGSize) {
        guard !isLuminanceReduced else { return }
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [
                    Palette.dataCyan.opacity(0.10),
                    Palette.dataCyan.opacity(0.02),
                    .clear
                ]),
                center: geometry.center,
                startRadius: 0,
                endRadius: geometry.radius
            )
        )
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
            let isOuter = fraction == 1.0
            // A soft glow pass behind the outer ring anchors the scope.
            if isOuter && !isLuminanceReduced {
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(ringColor.opacity(0.22)),
                    lineWidth: 2.5
                )
            }
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(ringColor),
                lineWidth: isOuter ? 1.0 : 0.5
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
        drawCardinalTicks(in: context)
    }

    /// N/E/S/W ticks on the outer ring — compass furniture that rotates with
    /// the scope, so north stays north in heading-up mode.
    private func drawCardinalTicks(in context: GraphicsContext) {
        guard !isLuminanceReduced else { return }
        let outer = geometry.ringRadius(1.0)
        let inner = outer - 5
        for degrees in [0.0, 90.0, 180.0, 270.0] {
            let relative = (degrees - geometry.rotation).radians
            var path = Path()
            path.move(to: CGPoint(
                x: geometry.center.x + inner * CGFloat(sin(relative)),
                y: geometry.center.y - inner * CGFloat(cos(relative))
            ))
            path.addLine(to: CGPoint(
                x: geometry.center.x + outer * CGFloat(sin(relative)),
                y: geometry.center.y - outer * CGFloat(cos(relative))
            ))
            context.stroke(path, with: .color(ringColor.opacity(0.6)), lineWidth: 1)
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

    /// Targets whose glyphs would overlap on screen are drawn as one glyph
    /// with a count — stacked approaches and formation flying otherwise paint
    /// over each other into a single unreadable dot.
    private func drawBlips(in context: GraphicsContext) {
        let clusterRadius: CGFloat = 7
        let positioned = targets.map { target in
            (
                target: target,
                point: geometry.point(bearingDegrees: target.bearingDegrees, distanceNM: target.distanceNM)
            )
        }

        var clusters: [[(target: TrackedTarget, point: CGPoint)]] = []
        for item in positioned {
            if let index = clusters.firstIndex(where: { cluster in
                cluster.contains { $0.point.distance(to: item.point) <= clusterRadius }
            }) {
                clusters[index].append(item)
            } else {
                clusters.append([item])
            }
        }

        for cluster in clusters {
            if cluster.count == 1, let single = cluster.first {
                drawBlip(for: single.target, at: single.point, in: context)
            } else {
                drawCluster(cluster, in: context)
            }
        }
    }

    private func drawBlip(for target: TrackedTarget, at position: CGPoint, in context: GraphicsContext) {
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

        // Soft glow behind the glyph: a wider, faint fill in the same colour. One extra fill per
        // blip is cheap, and it lifts the scope off the flat disc look.
        if !isLuminanceReduced {
            let halo = Path(ellipseIn: CGRect(x: position.x - 5.5, y: position.y - 5.5, width: 11, height: 11))
            context.fill(halo, with: .color(color.opacity(opacity * 0.22)))
        }

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

    /// One glyph for a stack of targets. Colour follows the most important
    /// member (emergency > pinned/nearest > uncertain); the count makes the
    /// pile visible.
    private func drawCluster(
        _ cluster: [(target: TrackedTarget, point: CGPoint)],
        in context: GraphicsContext
    ) {
        let primary = cluster.map(\.target).min { severity($0) < severity($1) } ?? cluster[0].target
        let point = geometry.point(bearingDegrees: primary.bearingDegrees, distanceNM: primary.distanceNM)
        let color = Palette.dimmed(
            Palette.target(
                primary,
                isSelected: primary.id == nearestID,
                isPinned: pinned.contains(primary.id)
            ),
            isLuminanceReduced: isLuminanceReduced
        )
        // A fading member makes the whole cluster tentative.
        let opacity = cluster.contains(where: { $0.target.isFading }) ? 0.5 : 1.0

        if !isLuminanceReduced {
            let halo = Path(ellipseIn: CGRect(x: point.x - 8.5, y: point.y - 8.5, width: 17, height: 17))
            context.fill(halo, with: .color(color.opacity(opacity * 0.2)))
        }
        let disc = Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
        context.fill(disc, with: .color(color.opacity(opacity)))

        var label = context.resolve(
            Text("\(cluster.count)")
                .font(.system(size: 8, weight: .bold, design: .rounded).monospacedDigit())
        )
        label.shading = .color(Palette.scopeBase)
        context.draw(label, at: point)
    }

    /// Lowest number wins the cluster colour: emergency, then pinned/nearest,
    /// then uncertain positions, then ordinary white.
    private func severity(_ target: TrackedTarget) -> Int {
        if target.aircraft.isAlerting { return 0 }
        if target.id == nearestID || pinned.contains(target.id) { return 1 }
        if target.position.needsCaution { return 2 }
        return 3
    }

    /// The "you are here" marker: a crosshair + ring + dot, so the scope's
    /// reference point reads as intentional rather than a speck of dust.
    private func drawCentre(in context: GraphicsContext) {
        let color = Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced)
        let c = geometry.center

        if !isLuminanceReduced {
            // Soft glow behind the whole marker.
            let glow = Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            context.fill(glow, with: .color(color.opacity(0.18)))
        }

        // Crosshair ticks.
        for degrees in [0.0, 90.0, 180.0, 270.0] {
            let relative = (degrees - geometry.rotation).radians
            let inner: CGFloat = 4.5
            let outer: CGFloat = 8
            var tick = Path()
            tick.move(to: CGPoint(
                x: c.x + inner * CGFloat(sin(relative)),
                y: c.y - inner * CGFloat(cos(relative))
            ))
            tick.addLine(to: CGPoint(
                x: c.x + outer * CGFloat(sin(relative)),
                y: c.y - outer * CGFloat(cos(relative))
            ))
            context.stroke(tick, with: .color(color.opacity(0.7)), lineWidth: 0.75)
        }

        // Ring and centre dot.
        let ring = Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        context.stroke(ring, with: .color(color.opacity(0.9)), lineWidth: 1)
        let dot = Path(ellipseIn: CGRect(x: c.x - 1.25, y: c.y - 1.25, width: 2.5, height: 2.5))
        context.fill(dot, with: .color(color))
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

// MARK: - Sweep

/// Not decoration: the sweep points where the device is facing, so the scope also answers "which
/// way am I looking?". Drawn as a classic radar beam — a bright leading edge with a fading wedge
/// trail behind it. Under Reduce Motion it becomes a static tick with no animation.
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

            if !isStatic {
                // Fading wedge trail behind the leading edge — the classic
                // radar beam. ~14° of arc (drawn as a chord triangle: at this
                // angle the chord and the arc are visually identical, and a
                // triangle can't get its sweep direction wrong).
                let trailDegrees = 14.0
                let trailRadians = (angle - trailDegrees).radians
                let trailTip = CGPoint(
                    x: geometry.center.x + geometry.radius * CGFloat(sin(trailRadians)),
                    y: geometry.center.y - geometry.radius * CGFloat(cos(trailRadians))
                )

                var wedge = Path()
                wedge.move(to: geometry.center)
                wedge.addLine(to: trailTip)
                wedge.addLine(to: tip)
                wedge.closeSubpath()

                context.fill(
                    wedge,
                    with: .linearGradient(
                        Gradient(colors: [
                            Palette.dataCyan.opacity(0.28),
                            Palette.dataCyan.opacity(0.05)
                        ]),
                        startPoint: tip,
                        endPoint: trailTip
                    )
                )
            }

            // Leading edge: a bright, slightly wider line.
            var path = Path()
            path.move(to: geometry.center)
            path.addLine(to: tip)

            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [Palette.dataCyan.opacity(0.05), Palette.dataCyan.opacity(0.85)]),
                    startPoint: geometry.center,
                    endPoint: tip
                ),
                lineWidth: isStatic ? 1 : 1.5
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
