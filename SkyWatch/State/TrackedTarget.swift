import Foundation

/// One point in a blip's tail.
struct TrailPoint: Sendable, Hashable {
    let coordinate: Coordinate
    let timestamp: Date
}

/// An aircraft as the app tracks it over time, rather than as a single response saw it.
///
/// Distance and bearing are computed once per merge and stored, because the list sorts by distance
/// on every redraw and recomputing a great circle per row per frame is wasted battery.
struct TrackedTarget: Sendable, Hashable, Identifiable {
    /// The raw hex, `~` prefix included — identity, not display.
    let id: String
    var aircraft: Aircraft
    var position: ResolvedPosition
    var distanceNM: Double
    /// True bearing from the observer to the target, 0..<360.
    var bearingDegrees: Double
    /// Oldest first, newest last. Capped at `TargetMerger.trailLength`.
    var trail: [TrailPoint]
    /// Consecutive responses this target has been missing from.
    var missedCycles: Int
    var firstSeen: Date
    var lastSeen: Date
    /// Whether the proximity haptic has already fired for this target this session.
    var hasAlerted: Bool
    /// Where and when this target will pass closest, when it is moving and we know its track.
    var closestApproach: ClosestApproach?

    var isFading: Bool { missedCycles > 0 }

    /// Everything VoiceOver needs in one utterance, in the order a pilot would want it.
    func accessibilityDescription(unitSystem: UnitSystem) -> String {
        var parts: [String] = [aircraft.displayName]
        parts.append(Units.distance(nauticalMiles: distanceNM, system: unitSystem).spoken)
        parts.append(Units.bearing(bearingDegrees).spoken)

        if let altitude = aircraft.altBaro {
            switch altitude {
            case .onGround:
                parts.append("on the ground")
            case .feet(let feet):
                parts.append(Units.altitude(feet: Double(feet), system: unitSystem).spoken)
            }
        }

        switch aircraft.verticalTrend {
        case .climbing: parts.append("climbing")
        case .descending: parts.append("descending")
        case .level: break
        }

        if aircraft.isMilitary { parts.append("military") }
        if aircraft.isAlerting { parts.append("emergency") }
        if position.source == .mlat { parts.append("multilaterated position") }
        if position.source == .estimated { parts.append("estimated position") }
        if position.isStale, let age = position.ageSeconds {
            parts.append("position \(Units.age(seconds: age)) old")
        }

        return parts.joined(separator: ", ")
    }
}

/// Folds a fresh response into the targets already on screen.
///
/// Replacing the array wholesale would teleport every blip and throw away the trails, so targets
/// are matched by hex and updated in place. A target that goes missing is kept — and visibly faded
/// — for one cycle, because a single dropped position report is routine at the edge of coverage.
struct TargetMerger: Sendable {
    static let trailLength = 3
    static let dropAfterMissedCycles = 2
    /// The most targets tracked at once. The feed can legitimately return several hundred
    /// aircraft over a busy airport; past roughly this many, the list is unreadable and the
    /// per-frame `Canvas` draw and SwiftUI diffing cost more than the extra blips earn. The
    /// cap keeps the nearest, which is exactly the set that matters.
    static let maxTrackedTargets = 60

    var trailLength: Int = TargetMerger.trailLength
    var dropAfterMissedCycles: Int = TargetMerger.dropAfterMissedCycles
    var maxTrackedTargets: Int = TargetMerger.maxTrackedTargets

    /// - Parameter penalizeMissing: whether targets absent from `response` count as missed. False
    ///   for a single-aircraft detail lookup, which says nothing about the rest of the sky.
    func merge(
        existing: [TrackedTarget],
        response: [Aircraft],
        observer: Coordinate,
        now: Date = Date(),
        penalizeMissing: Bool = true
    ) -> [TrackedTarget] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var seenIDs = Set<String>()

        for aircraft in response {
            // No hex means no stable identity, so it cannot be tracked across refreshes.
            guard let hex = aircraft.hex, !hex.isEmpty else { continue }
            guard let position = aircraft.resolvedPosition else { continue }

            seenIDs.insert(hex)

            let distance = Geodesy.distanceNM(from: observer, to: position.coordinate)
            let bearing = Geodesy.initialBearing(from: observer, to: position.coordinate)
            let approach = Geodesy.closestPointOfApproach(
                target: position.coordinate,
                trackDegrees: aircraft.track,
                groundSpeedKt: aircraft.groundSpeed,
                observer: observer
            )

            if var target = byID[hex] {
                // Only extend the tail when the aircraft actually moved, so a parked target doesn't
                // accumulate a smear of identical points.
                if target.position.coordinate != position.coordinate {
                    target.trail.append(TrailPoint(coordinate: target.position.coordinate, timestamp: target.lastSeen))
                    if target.trail.count > trailLength {
                        target.trail.removeFirst(target.trail.count - trailLength)
                    }
                }
                target.aircraft = aircraft
                target.position = position
                target.distanceNM = distance
                target.bearingDegrees = bearing
                target.closestApproach = approach
                target.missedCycles = 0
                target.lastSeen = now
                byID[hex] = target
            } else {
                byID[hex] = TrackedTarget(
                    id: hex,
                    aircraft: aircraft,
                    position: position,
                    distanceNM: distance,
                    bearingDegrees: bearing,
                    trail: [],
                    missedCycles: 0,
                    firstSeen: now,
                    lastSeen: now,
                    hasAlerted: false,
                    closestApproach: approach
                )
            }
        }

        guard penalizeMissing else {
            return capped(byID.values.sorted { $0.distanceNM < $1.distanceNM })
        }

        for (id, var target) in byID where !seenIDs.contains(id) {
            target.missedCycles += 1
            if target.missedCycles >= dropAfterMissedCycles {
                byID.removeValue(forKey: id)
            } else {
                byID[id] = target
            }
        }

        return capped(byID.values.sorted { $0.distanceNM < $1.distanceNM })
    }

    /// Keeps only the nearest `maxTrackedTargets`. Applied to both merge paths — a detail lookup
    /// must not be able to grow the tracked set past what a scan can.
    private func capped(_ targets: [TrackedTarget]) -> [TrackedTarget] {
        targets.count <= maxTrackedTargets ? targets : Array(targets.prefix(maxTrackedTargets))
    }
}
