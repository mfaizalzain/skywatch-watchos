import Foundation

/// Sample targets for `#Preview`s, built by decoding real-shaped JSON rather than by hand-filling
/// forty optional fields. A side effect worth having: if the decoder ever breaks, the previews
/// break with it.
enum PreviewData {
    static let observer = Coordinate(latitude: 37.3349, longitude: -122.0090)

    static func aircraft(_ json: String) -> Aircraft {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Aircraft.self, from: data) else {
            // Previews should degrade, not trap.
            return (try? JSONDecoder().decode(Aircraft.self, from: Data("{}".utf8))) ?? emptyAircraft
        }
        return decoded
    }

    private static let emptyAircraft: Aircraft = {
        // `{}` decodes cleanly because every field is optional; this is only a compiler-satisfying
        // fallback for the impossible case.
        try! JSONDecoder().decode(Aircraft.self, from: Data("{}".utf8))
    }()

    // MARK: - Aircraft

    static let airliner = aircraft("""
    {"hex":"a1b2c3","flight":"UAL328  ","r":"N77258","t":"B739","category":"A3",
     "lat":37.4021,"lon":-122.0553,"alt_baro":12000,"alt_geom":12350,"gs":312.4,
     "ias":280,"tas":330,"mach":0.52,"track":210.3,"baro_rate":-1216,"true_heading":208.1,
     "squawk":"3651","emergency":"none","nav_modes":["autopilot","vnav","lnav"],
     "nav_altitude_mcp":10000,"nav_qnh":1013.6,"seen":0.4,"seen_pos":0.9,"rssi":-14.2,
     "type":"adsb_icao","nic":8,"rc":186,"nac_p":9,"nac_v":2,"sil":3,"sil_type":"perhour",
     "gva":2,"sda":2,"version":2,"wd":270,"ws":42,"oat":-18,"tat":-4,"dbFlags":0}
    """)

    static let military = aircraft("""
    {"hex":"ae1234","flight":"RCH471  ","r":"08-8191","t":"C17","category":"A5",
     "lat":37.2210,"lon":-121.9330,"alt_baro":24000,"gs":410,"track":45.0,"baro_rate":1920,
     "squawk":"4517","seen":1.1,"seen_pos":1.4,"rssi":-19.8,"type":"adsb_icao","dbFlags":1}
    """)

    static let emergency = aircraft("""
    {"hex":"c0ffee","flight":"SWA1234 ","t":"B738","lat":37.3800,"lon":-122.0500,
     "alt_baro":4200,"gs":210,"track":95.0,"baro_rate":-640,"squawk":"7700",
     "emergency":"general","seen":0.6,"seen_pos":0.8,"rssi":-11.0,"type":"adsb_icao"}
    """)

    static let mlatStale = aircraft("""
    {"hex":"~abc999","flight":"N512TS  ","t":"C172","lat":37.2600,"lon":-122.1400,
     "alt_baro":3100,"gs":98,"track":310.0,"seen":92,"seen_pos":92,"rssi":-27.4,"type":"mlat"}
    """)

    static let onGround = aircraft("""
    {"hex":"d00d00","flight":"ASA119  ","t":"B39M","lat":37.3626,"lon":-121.9290,
     "alt_baro":"ground","gs":12,"track":150.0,"seen":0.3,"seen_pos":0.5,"type":"adsb_icao"}
    """)

    static let estimated = aircraft("""
    {"hex":"beef01","t":"GLF6","rr_lat":37.44,"rr_lon":-122.15,"seen":41,"type":"mode_s"}
    """)

    // MARK: - Tracked targets

    static func target(
        _ aircraft: Aircraft,
        trail: Int = 2,
        missedCycles: Int = 0
    ) -> TrackedTarget {
        let position = aircraft.resolvedPosition ?? ResolvedPosition(
            coordinate: observer,
            source: .estimated,
            ageSeconds: 120
        )

        // Walk the tail backwards along the aircraft's own track so the trail points the right way.
        let trailPoints: [TrailPoint] = (1...max(trail, 1)).reversed().map { step in
            let bearing = Geodesy.normalized0to360((aircraft.track ?? 0) + 180)
            let offsetNM = Double(step) * 0.35
            let latitude = position.coordinate.latitude + (offsetNM / 60) * cos(bearing.radians)
            let longitude = position.coordinate.longitude
                + (offsetNM / (60 * cos(position.coordinate.latitude.radians))) * sin(bearing.radians)
            return TrailPoint(
                coordinate: Coordinate(latitude: latitude, longitude: longitude),
                timestamp: Date().addingTimeInterval(-Double(step) * 10)
            )
        }

        return TrackedTarget(
            id: aircraft.hex ?? UUID().uuidString,
            aircraft: aircraft,
            position: position,
            distanceNM: Geodesy.distanceNM(from: observer, to: position.coordinate),
            bearingDegrees: Geodesy.initialBearing(from: observer, to: position.coordinate),
            trail: trail > 0 ? trailPoints : [],
            missedCycles: missedCycles,
            firstSeen: Date().addingTimeInterval(-120),
            lastSeen: Date(),
            hasAlerted: false,
            closestApproach: Geodesy.closestPointOfApproach(
                target: position.coordinate,
                trackDegrees: aircraft.track,
                groundSpeedKt: aircraft.groundSpeed,
                observer: observer
            )
        )
    }

    static var airlinerTarget: TrackedTarget { target(airliner) }
    static var militaryTarget: TrackedTarget { target(military) }
    static var emergencyTarget: TrackedTarget { target(emergency) }
    static var staleMLATTarget: TrackedTarget { target(mlatStale) }
    static var groundTarget: TrackedTarget { target(onGround) }
    static var estimatedTarget: TrackedTarget { target(estimated) }

    static var handful: [TrackedTarget] {
        [airlinerTarget, militaryTarget, staleMLATTarget, emergencyTarget]
            .sorted { $0.distanceNM < $1.distanceNM }
    }

    /// 32 targets scattered around the observer, for checking that the scope stays legible when the
    /// sky is busy.
    static var dense: [TrackedTarget] {
        var generator = SplitMix64(seed: 0x5C1E_5CA7_1234_5678)
        return (0..<32).map { index in
            let bearing = Double(index) * 11.25 + generator.nextDouble(in: -4...4)
            let distance = generator.nextDouble(in: 0.8...19.5)
            let latitude = observer.latitude + (distance / 60) * cos(bearing.radians)
            let longitude = observer.longitude
                + (distance / (60 * cos(observer.latitude.radians))) * sin(bearing.radians)
            let coordinate = Coordinate(latitude: latitude, longitude: longitude)

            let source: PositionSource = index % 7 == 0 ? .mlat : .reported
            let age: TimeInterval = index % 5 == 0 ? 90 : 2

            var base = airliner
            if index % 9 == 0 { base = military }

            return TrackedTarget(
                id: String(format: "sim%03d", index),
                aircraft: base,
                position: ResolvedPosition(coordinate: coordinate, source: source, ageSeconds: age),
                distanceNM: distance,
                bearingDegrees: Geodesy.normalized0to360(bearing),
                trail: [],
                missedCycles: 0,
                firstSeen: Date(),
                lastSeen: Date(),
                hasAlerted: false,
                closestApproach: nil
            )
        }
        .sorted { $0.distanceNM < $1.distanceNM }
    }
}

/// A tiny deterministic generator so the dense preview looks the same on every redraw — a scope
/// that reshuffles itself between snapshots is useless for judging layout.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
