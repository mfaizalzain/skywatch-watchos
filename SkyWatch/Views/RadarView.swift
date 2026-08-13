import SwiftUI

/// The scope. Centre is you; blips are aircraft, rotated to their track so you can see where each
/// one is going rather than only where it is.
struct RadarView: View {
    @Environment(ScanStore.self) private var store
    @Environment(FlightTrackStore.self) private var flightStore
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.requestTrackTab) private var requestTrackTab

    @State private var crownPosition: Double = 0
    @State private var crownFeedback: String?
    @State private var crownFeedbackTask: Task<Void, Never>?
    @State private var clusterSelection: ClusterSelection?

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
                    isLuminanceReduced: isLuminanceReduced,
                    deviceHeading: deviceHeading
                )

                SweepLine(
                    geometry: geometry,
                    headingDegrees: store.location.heading,
                    isStatic: reduceMotion || isLuminanceReduced
                )

                // The canvas can't be tapped and can't be read aloud, so the interaction layer is
                // made of real views sitting on top of it.
                blipTargets(geometry: geometry)

                // Transient confirmation while the crown re-ranges the scope. The haptic says a
                // detent happened; this says which one, in the middle of the action.
                if let crownFeedback {
                    Text(crownFeedback)
                        .font(Typography.primaryValue)
                        .foregroundStyle(Palette.dataCyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Palette.dataCyan.opacity(0.14))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Palette.dataCyan.opacity(0.6), lineWidth: 0.75)
                        )
                        .position(x: geometry.center.x, y: geometry.center.y - geometry.radius * 0.42)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .accessibilityHidden(true)
                }

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
            crownFeedbackTask?.cancel()
        }
        .onChange(of: settings.isHeadingUp) { _, headingUp in
            headingUp ? store.location.startUpdatingHeading() : store.location.stopUpdatingHeading()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Radar scope")
        .accessibilityValue(scopeAccessibilityValue)
        .sheet(item: $clusterSelection) { selection in
            NavigationStack {
                List(selection.members.sorted { $0.distanceNM < $1.distanceNM }) { member in
                    NavigationLink(value: member.id) {
                        AircraftRow(
                            target: member,
                            unitSystem: settings.unitSystem,
                            deviceHeading: deviceHeading,
                            isPinned: settings.isPinned(member.id),
                            isLuminanceReduced: isLuminanceReduced
                        )
                        .glassCardBackground(cornerRadius: 12)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.carousel)
                .containerBackground(Palette.scopeBase, for: .navigation)
                .navigationTitle {
                    Text("\(selection.members.count) aircraft")
                        .foregroundStyle(Palette.dataCyan)
                }
                .navigationDestination(for: String.self) { hex in
                    AircraftDetailView(hex: hex)
                }
            }
        }
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
            // What slice of sky is on screen and how much is in it — the two numbers that frame
            // every other reading on the scope.
            Badge(
                text: "\(Int(settings.radius.nauticalMiles)) nm · \(targets.count)",
                color: Palette.dataCyan,
                isLuminanceReduced: isLuminanceReduced
            )
            .accessibilityLabel(
                "Range \(Int(settings.radius.nauticalMiles)) nautical miles, \(targets.count) aircraft in range"
            )

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

            // The mode the scope is *actually* in — when heading-up was requested but the compass
            // isn't reporting, this honestly says north-up rather than promising a heading.
            Badge(
                text: deviceHeading == nil ? "N-UP" : "H-UP",
                color: Palette.dataCyan.opacity(0.75),
                isLuminanceReduced: isLuminanceReduced
            )
            .accessibilityLabel(deviceHeading == nil ? "North up" : "Heading up")
        }
        .padding(.top, 2)
    }

    // MARK: - Hit targets

    /// One tappable region per *cluster*, not per blip: a lone blip links straight to that
    /// aircraft, while a stacked cluster opens a picker so the wearer can choose a member.
    @ViewBuilder
    private func blipTargets(geometry: ScopeGeometry) -> some View {
        let targets = orderedForDrawing(
            self.targets,
            nearestID: store.nearest?.id,
            pinned: settings.pinnedHexes
        )
        let clusters = scopeClusters(targets, geometry: geometry)

        ForEach(clusters, id: \.self) { cluster in
            if cluster.count == 1, let target = cluster.first {
                let point = geometry.point(
                    bearingDegrees: target.bearingDegrees,
                    distanceNM: target.distanceNM
                )
                let tapSize = max(28, 28 * geometry.glyphScale)

                NavigationLink(value: target.id) {
                    Color.clear
                        .frame(width: tapSize, height: tapSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(point)
                .accessibilityLabel(target.accessibilityDescription(unitSystem: settings.unitSystem))
                .contextMenu { targetContextMenu(target) }
            } else {
                clusterButton(cluster, geometry: geometry)
            }
        }
    }

    /// The invisible control behind a stacked cluster. Sized to the cluster's actual spread so no
    /// member's position falls outside the tappable area, with a 28 pt floor like a lone blip.
    @ViewBuilder
    private func clusterButton(_ cluster: [TrackedTarget], geometry: ScopeGeometry) -> some View {
        let points = cluster.map {
            geometry.point(bearingDegrees: $0.bearingDegrees, distanceNM: $0.distanceNM)
        }
        let minX = points.map(\.x).min() ?? geometry.center.x
        let maxX = points.map(\.x).max() ?? geometry.center.x
        let minY = points.map(\.y).min() ?? geometry.center.y
        let maxY = points.map(\.y).max() ?? geometry.center.y
        let tapFloor = max(28, 28 * geometry.glyphScale)
        let width = max(tapFloor, maxX - minX + 8)
        let height = max(tapFloor, maxY - minY + 8)
        let position = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        Button {
            clusterSelection = ClusterSelection(members: cluster)
        } label: {
            Color.clear
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(position)
        .accessibilityLabel("\(cluster.count) aircraft grouped together")
        .contextMenu {
            targetContextMenu(
                clusterPrimary(cluster, nearestID: store.nearest?.id, pinned: settings.pinnedHexes)
            )
        }
    }

    /// Long-press on a blip: pin it (or unpin) and, when the callsign is trackable, hand it to
    /// the Track tab — the same two actions the list's swipe actions offer.
    @ViewBuilder
    private func targetContextMenu(_ target: TrackedTarget) -> some View {
        Button {
            settings.togglePin(target.id)
            Haptics.selectionChanged()
        } label: {
            Label(
                settings.isPinned(target.id) ? "Unpin" : "Pin",
                systemImage: settings.isPinned(target.id) ? "pin.slash" : "pin"
            )
        }

        if let callsign = target.aircraft.callsign, FlightNumber.parse(callsign) != nil {
            Button {
                guard let number = FlightNumber.parse(callsign) else { return }
                flightStore.startTracking(number: number)
                Haptics.flightMilestone()
                requestTrackTab()
            } label: {
                Label("Track", systemImage: "location.fill")
            }
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
        showCrownFeedback("\(Int(radius.nauticalMiles)) nm")
        Haptics.crownDetent()
        // One request when the crown stops, not one per detent — four fast clicks would otherwise
        // be four requests.
        store.refreshAfterSettling()
    }

    private func widen(to radius: ScanRadius) {
        settings.radius = radius
        showCrownFeedback("\(Int(radius.nauticalMiles)) nm")
        if let index = ScanRadius.allCases.firstIndex(of: radius) {
            crownPosition = Double(index)
        }
        Task { await store.refresh() }
    }

    /// Flashes the new range over the scope and fades it out shortly after. The crown already
    /// clicks; this makes the click legible.
    private func showCrownFeedback(_ text: String) {
        crownFeedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { crownFeedback = text }
        crownFeedbackTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { crownFeedback = nil }
        }
    }
}

/// The member list opened by tapping a stacked cluster, so the wearer can pick which aircraft
/// in the pile they actually meant.
private struct ClusterSelection: Identifiable {
    let id = UUID()
    let members: [TrackedTarget]
}

// MARK: - Cluster and draw-order helpers

/// Blips drawn last sit on top. Emergency, then nearest/pinned, then uncertain, then ordinary —
/// the blips that matter are never painted over by the ones that don't.
private func orderedForDrawing(
    _ targets: [TrackedTarget],
    nearestID: TrackedTarget.ID?,
    pinned: Set<String>
) -> [TrackedTarget] {
    targets.sorted { lhs, rhs in
        let lhsPriority = drawOrderPriority(lhs, nearestID: nearestID, pinned: pinned)
        let rhsPriority = drawOrderPriority(rhs, nearestID: nearestID, pinned: pinned)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return lhs.distanceNM < rhs.distanceNM
    }
}

/// Higher draws later (on top). Inverse of `clusterSeverity`, so the two stay in step.
private func drawOrderPriority(
    _ target: TrackedTarget,
    nearestID: TrackedTarget.ID?,
    pinned: Set<String>
) -> Int {
    3 - clusterSeverity(target, nearestID: nearestID, pinned: pinned)
}

/// Lowest number wins the cluster colour: emergency, then pinned/nearest,
/// then uncertain positions, then ordinary white.
private func clusterSeverity(
    _ target: TrackedTarget,
    nearestID: TrackedTarget.ID?,
    pinned: Set<String>
) -> Int {
    if target.aircraft.isAlerting { return 0 }
    if target.id == nearestID || pinned.contains(target.id) { return 1 }
    if target.position.needsCaution { return 2 }
    return 3
}

private func clusterPrimary(
    _ cluster: [TrackedTarget],
    nearestID: TrackedTarget.ID?,
    pinned: Set<String>
) -> TrackedTarget {
    cluster.min {
        clusterSeverity($0, nearestID: nearestID, pinned: pinned)
            < clusterSeverity($1, nearestID: nearestID, pinned: pinned)
    } ?? cluster[0]
}

/// Groups targets whose glyphs would overlap on screen into one cluster. Must agree exactly with
/// what the canvas draws, so the invisible hit targets line up with the visible discs.
private func scopeClusters(
    _ targets: [TrackedTarget],
    geometry: ScopeGeometry
) -> [[TrackedTarget]] {
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
    return clusters.map { $0.map(\.target) }
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
    let deviceHeading: Double?

    var body: some View {
        Canvas { context, size in
            drawBackdrop(in: context, size: size)
            drawRings(in: context)
            drawHeadingReadout(in: context)
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
                    Palette.dataCyan.opacity(0.08),
                    Palette.dataCyan.opacity(0.015),
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
                    with: .color(ringColor.opacity(0.16)),
                    lineWidth: 2.5
                )
            }
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(ringColor),
                lineWidth: isOuter ? 1.0 : 0.5
            )

            // Ring labels sit low-left, out of the way of the nearest-target callout. The full
            // range has its own home in the top status badge now, so only ⅓ and ⅔ get labels.
            if fraction != 1.0 {
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

        // The letters are the point of the ticks: without them the scope can't answer
        // "which way is north?" at a glance. N gets the weight; E/S/W stay quiet.
        for (degrees, letter) in [(0.0, "N"), (90.0, "E"), (180.0, "S"), (270.0, "W")] {
            let relative = (degrees - geometry.rotation).radians
            let letterRadius = outer - 13
            var label = context.resolve(
                Text(letter)
                    .font(.system(size: degrees == 0 ? 9 : 7, weight: degrees == 0 ? .bold : .regular, design: .rounded))
            )
            label.shading = .color(
                degrees == 0
                    ? Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced)
                    : ringColor.opacity(0.55)
            )
            context.draw(
                label,
                at: CGPoint(
                    x: geometry.center.x + letterRadius * CGFloat(sin(relative)),
                    y: geometry.center.y - letterRadius * CGFloat(cos(relative))
                )
            )
        }
    }

    /// "287°" pinned to the top of the scope in heading-up mode, so the rotated scope always
    /// says what bearing "ahead" is. Skipped on Always-On along with the rest of the compass
    /// furniture.
    private func drawHeadingReadout(in context: GraphicsContext) {
        guard !isLuminanceReduced, let deviceHeading else { return }
        let bearing = Units.bearing(deviceHeading)
        var label = context.resolve(
            Text("\(bearing.value)\(bearing.unit)")
                .font(Typography.smallValue)
        )
        label.shading = .color(
            Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced).opacity(0.85)
        )
        context.draw(
            label,
            at: CGPoint(x: geometry.center.x, y: geometry.center.y - geometry.radius + 24)
        )
    }

    /// Two or three previous positions, fading out. This is the one piece of ornament that earns
    /// its place: it turns a dot into a direction of travel.
    private func drawTrail(for target: TrackedTarget, in context: GraphicsContext) {
        guard !target.trail.isEmpty, let observer else { return }

        let dotRadius = 1.1 * geometry.glyphScale
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
            let dot = Path(
                ellipseIn: CGRect(
                    x: position.x - dotRadius,
                    y: position.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
            )
            context.fill(dot, with: .color(color.opacity(opacity)))
        }
    }

    /// Targets whose glyphs would overlap on screen are drawn as one glyph
    /// with a count — stacked approaches and formation flying otherwise paint
    /// over each other into a single unreadable dot.
    private func drawBlips(in context: GraphicsContext) {
        let targets = orderedForDrawing(self.targets, nearestID: nearestID, pinned: pinned)
        for cluster in scopeClusters(targets, geometry: geometry) {
            if cluster.count == 1, let single = cluster.first {
                let point = geometry.point(
                    bearingDegrees: single.bearingDegrees,
                    distanceNM: single.distanceNM
                )
                drawBlip(for: single, at: point, in: context)
            } else {
                drawCluster(cluster, in: context)
            }
        }
    }

    private func drawBlip(for target: TrackedTarget, at position: CGPoint, in context: GraphicsContext) {
        let scale = geometry.glyphScale
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
            let halo = Path(
                ellipseIn: CGRect(
                    x: position.x - 6 * scale,
                    y: position.y - 6 * scale,
                    width: 12 * scale,
                    height: 12 * scale
                )
            )
            context.fill(halo, with: .color(color.opacity(opacity * 0.18)))
        }

        if let track = target.aircraft.track {
            var path = Path()
            let length: CGFloat = 5.5 * scale
            let width: CGFloat = 4 * scale
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
            let dot = Path(
                ellipseIn: CGRect(
                    x: position.x - 2.8 * scale,
                    y: position.y - 2.8 * scale,
                    width: 5.6 * scale,
                    height: 5.6 * scale
                )
            )
            context.fill(dot, with: .color(color.opacity(opacity)))
        }

        // The nearest aircraft earns a selection ring, so it reads as special even if its
        // magenta is hard to tell from white or red, and even when colour is dimmed.
        if target.id == nearestID {
            let ring = Path(
                ellipseIn: CGRect(
                    x: position.x - 8 * scale,
                    y: position.y - 8 * scale,
                    width: 16 * scale,
                    height: 16 * scale
                )
            )
            context.stroke(ring, with: .color(color.opacity(0.9)), lineWidth: 1)
        }

        // A blip that is genuinely climbing or descending earns the same tiny chevron the list
        // rows carry — but only past a real rate, so a slow 100 fpm drift doesn't add noise.
        // Drawn above-right of the blip so it never fights the glyph's own rotation.
        let verticalRate = target.aircraft.baroRate ?? target.aircraft.geomRate
        if !isLuminanceReduced, let verticalRate, abs(verticalRate) >= 500 {
            let up = verticalRate > 0
            var chevron = Path()
            if up {
                chevron.move(to: CGPoint(x: -3 * scale, y: 1.5 * scale))
                chevron.addLine(to: CGPoint(x: 0, y: -1.5 * scale))
                chevron.addLine(to: CGPoint(x: 3 * scale, y: 1.5 * scale))
            } else {
                chevron.move(to: CGPoint(x: -3 * scale, y: -1.5 * scale))
                chevron.addLine(to: CGPoint(x: 0, y: 1.5 * scale))
                chevron.addLine(to: CGPoint(x: 3 * scale, y: -1.5 * scale))
            }
            context.stroke(
                chevron.applying(
                    CGAffineTransform(translationX: position.x + 9 * scale, y: position.y - 4 * scale)
                ),
                with: .color(Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced).opacity(opacity * 0.75)),
                lineWidth: 1
            )
        }

        // Estimated positions get a ring instead of a solid glyph — visibly not a fix.
        if target.position.source == .estimated {
            let ring = Path(
                ellipseIn: CGRect(
                    x: position.x - 5.5 * scale,
                    y: position.y - 5.5 * scale,
                    width: 11 * scale,
                    height: 11 * scale
                )
            )
            context.stroke(ring, with: .color(color.opacity(0.5)), lineWidth: 0.5)
        }
    }

    /// One glyph for a stack of targets. Colour follows the most important
    /// member (emergency > pinned/nearest > uncertain); the count makes the
    /// pile visible.
    private func drawCluster(
        _ cluster: [TrackedTarget],
        in context: GraphicsContext
    ) {
        let scale = geometry.glyphScale
        let primary = clusterPrimary(cluster, nearestID: nearestID, pinned: pinned)
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
        let opacity = cluster.contains(where: { $0.isFading }) ? 0.5 : 1.0

        if !isLuminanceReduced {
            let halo = Path(
                ellipseIn: CGRect(
                    x: point.x - 9.5 * scale,
                    y: point.y - 9.5 * scale,
                    width: 19 * scale,
                    height: 19 * scale
                )
            )
            context.fill(halo, with: .color(color.opacity(opacity * 0.16)))
        }
        let disc = Path(
            ellipseIn: CGRect(
                x: point.x - 7 * scale,
                y: point.y - 7 * scale,
                width: 14 * scale,
                height: 14 * scale
            )
        )
        context.fill(disc, with: .color(color.opacity(opacity)))

        if primary.id == nearestID {
            let ring = Path(
                ellipseIn: CGRect(
                    x: point.x - 10.5 * scale,
                    y: point.y - 10.5 * scale,
                    width: 21 * scale,
                    height: 21 * scale
                )
            )
            context.stroke(ring, with: .color(color.opacity(0.9)), lineWidth: 1)
        }

        var label = context.resolve(
            Text("\(cluster.count)")
                .font(.system(size: 9 * scale, weight: .bold, design: .rounded).monospacedDigit())
        )
        label.shading = .color(Palette.scopeBase)
        context.draw(label, at: point)
    }

    /// The "you are here" marker: a crosshair + ring + dot, so the scope's
    /// reference point reads as intentional rather than a speck of dust.
    private func drawCentre(in context: GraphicsContext) {
        let color = Palette.dimmed(Palette.dataCyan, isLuminanceReduced: isLuminanceReduced)
        let c = geometry.center

        if !isLuminanceReduced {
            // Soft glow behind the whole marker.
            let glow = Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            context.fill(glow, with: .color(color.opacity(0.14)))
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
                            Palette.dataCyan.opacity(0.22),
                            Palette.dataCyan.opacity(0.04)
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
                    Gradient(colors: [Palette.dataCyan.opacity(0.05), Palette.dataCyan.opacity(0.78)]),
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
