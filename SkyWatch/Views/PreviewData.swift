import Foundation

/// Sample targets for `#Preview`s, built by decoding real-shaped JSON rather than by hand-filling
/// forty optional fields. A side effect worth having: if the decoder ever breaks, the previews
/// break with it.
enum PreviewData {
    static let observer = Coordinate(latitude: 37.3349, longitude: -122.0090)

    /// `{}` decodes cleanly because every field is optional; this is only a fallback for the
    /// impossible case. Previews should degrade, not trap.
    private static let emptyAircraft: Aircraft = {
        (try? JSONDecoder().decode(Aircraft.self, from: Data("{}".utf8)))!
    }()

    // MARK: - Aircraft

    /// Timestamps are rendered relative to a fixed instant so the previews stay deterministic; the
    /// helper below re-stamps them against `Date()` when a fresh position is wanted.
    static func aircraft(_ json: String, positionAge: TimeInterval = 2) -> Aircraft {
        let stamped = json.replacingOccurrences(
            of: "$TIMESTAMP",
            with: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-positionAge))
        )
        guard let data = stamped.data(using: .utf8),
              let decoded = try? Self.decoder.decode(Aircraft.self, from: data) else {
            return emptyAircraft
        }
        return decoded
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let airliner = aircraft("""
    {"fa_flight_id":"UAL328-1700000000-airline-0001","ident":"UAL328","ident_icao":"UAL328",
     "ident_iata":"UA328","aircraft_type":"B739",
     "origin":{"code":"KSFO","code_icao":"KSFO","code_iata":"SFO","name":"San Francisco Intl","city":"San Francisco"},
     "destination":{"code":"KDEN","code_icao":"KDEN","code_iata":"DEN","name":"Denver Intl","city":"Denver"},
     "last_position":{"altitude":120,"altitude_change":"D","groundspeed":312,"heading":210,
      "latitude":37.4021,"longitude":-122.0553,"timestamp":"$TIMESTAMP","update_type":"A"}}
    """)

    static let lifeguard = aircraft("""
    {"fa_flight_id":"N911MD-1700000000-adhoc-0002","ident":"N911MD","ident_prefix":"L",
     "aircraft_type":"C560",
     "last_position":{"altitude":42,"altitude_change":"C","groundspeed":210,"heading":95,
      "latitude":37.3800,"longitude":-122.0500,"timestamp":"$TIMESTAMP","update_type":"A"}}
    """)

    static let mlatStale = aircraft("""
    {"fa_flight_id":"N512TS-1700000000-adhoc-0003","ident":"N512TS","aircraft_type":"C172",
     "last_position":{"altitude":31,"altitude_change":"-","groundspeed":98,"heading":310,
      "latitude":37.2600,"longitude":-122.1400,"timestamp":"$TIMESTAMP","update_type":"M"}}
    """, positionAge: 92)

    static let onGround = aircraft("""
    {"fa_flight_id":"ASA119-1700000000-airline-0004","ident":"ASA119","aircraft_type":"B39M",
     "last_position":{"altitude":0,"altitude_change":"-","groundspeed":12,"heading":150,
      "latitude":37.3626,"longitude":-121.9290,"timestamp":"$TIMESTAMP","update_type":"X"}}
    """)

    static let projected = aircraft("""
    {"fa_flight_id":"GLF6XX-1700000000-adhoc-0005","ident":"N600GX","aircraft_type":"GLF6",
     "last_position":{"altitude":410,"altitude_change":"-","groundspeed":480,"heading":20,
      "latitude":37.4400,"longitude":-122.1500,"timestamp":"$TIMESTAMP","update_type":"P"}}
    """, positionAge: 41)

    // MARK: - Tracked targets

    static func target(
        _ aircraft: Aircraft,
        trail: Int = 2,
        missedCycles: Int = 0
    ) -> TrackedTarget {
        let position = aircraft.resolvedPosition() ?? ResolvedPosition(
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
            id: aircraft.faFlightID ?? UUID().uuidString,
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
    static var lifeguardTarget: TrackedTarget { target(lifeguard) }
    static var staleMLATTarget: TrackedTarget { target(mlatStale) }
    static var groundTarget: TrackedTarget { target(onGround) }
    static var projectedTarget: TrackedTarget { target(projected) }

    static var handful: [TrackedTarget] {
        [airlinerTarget, lifeguardTarget, staleMLATTarget, projectedTarget]
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
            if index % 9 == 0 { base = lifeguard }

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
