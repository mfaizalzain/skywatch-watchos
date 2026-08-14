import Foundation

// MARK: - Altitude

/// AeroAPI reports altitude as an integer in *hundreds* of feet. Zero means the aircraft is on or
/// near the surface, which the scope treats as ground traffic.
enum BarometricAltitude: Sendable, Hashable {
    case feet(Int)
    case onGround

    /// - Parameter hundredsOfFeet: the raw `last_position.altitude` value.
    init(hundredsOfFeet: Int) {
        self = hundredsOfFeet <= 0 ? .onGround : .feet(hundredsOfFeet * 100)
    }

    var feetValue: Int? {
        if case .feet(let feet) = self { return feet }
        return nil
    }

    var isOnGround: Bool { self == .onGround }
}

// MARK: - Position source

/// How the position we are about to draw was obtained. Derived from AeroAPI's `update_type`.
enum PositionSource: Sendable, Hashable {
    /// A real position report — ADS-B, radar, datalink, oceanic or space-based.
    case reported
    /// Multilateration. Real, but with accuracy that varies with receiver geometry.
    case mlat
    /// Projected: FlightAware extrapolated this from an earlier fix. Not a fix, and must never be
    /// presented as one.
    case estimated

    /// `P` is projected, `M` is multilateration; everything else is a real report.
    init(updateType: String?) {
        switch updateType?.uppercased() {
        case "P": self = .estimated
        case "M": self = .mlat
        default: self = .reported
        }
    }

    var isPrecise: Bool { self == .reported }

    /// The label the detail screen shows for the underlying feed.
    static func label(updateType: String?) -> String {
        switch updateType?.uppercased() {
        case "A": "ADS-B"
        case "M": "MLAT"
        case "Z": "Radar"
        case "D": "Datalink"
        case "O": "Oceanic"
        case "S": "Space-based"
        case "X": "Surface"
        case "P": "Projected"
        default: "Unknown"
        }
    }
}

/// A position the UI can actually draw, together with everything it needs to qualify it.
struct ResolvedPosition: Sendable, Hashable {
    let coordinate: Coordinate
    let source: PositionSource
    /// Seconds since the position was measured.
    let ageSeconds: TimeInterval?

    /// A target is fresh only while its position is under a minute old.
    var isStale: Bool { (ageSeconds ?? 0) >= 60 }

    /// Projected positions are always uncertain; MLAT and stale fixes are worth a caution badge.
    var needsCaution: Bool { source != .reported || isStale }
}

// MARK: - Airport

/// The parts of AeroAPI's airport reference the watch has room to show.
struct AirportRef: Sendable, Hashable, Decodable {
    let code: String?
    let codeICAO: String?
    let codeIATA: String?
    let name: String?
    let city: String?

    enum CodingKeys: String, CodingKey {
        case code, name, city
        case codeICAO = "code_icao"
        case codeIATA = "code_iata"
    }

    /// Shortest unambiguous thing to print on a 45 mm screen.
    var displayCode: String? {
        codeIATA ?? codeICAO ?? code
    }
}

// MARK: - Position

/// `last_position` — the only positional data AeroAPI's flight search returns.
struct FlightPosition: Sendable, Hashable, Decodable {
    /// Hundreds of feet.
    let altitude: Int?
    /// `C` climbing, `D` descending, `-` level.
    let altitudeChange: String?
    /// Knots.
    let groundspeed: Int?
    /// Degrees, 0–360.
    let heading: Int?
    let latitude: Double?
    let longitude: Double?
    let timestamp: Date?
    /// P=projected, O=oceanic, Z=radar, A=ADS-B, M=multilateration, D=datalink, X=surface,
    /// S=space-based.
    let updateType: String?

    enum CodingKeys: String, CodingKey {
        case altitude, groundspeed, heading, latitude, longitude, timestamp
        case altitudeChange = "altitude_change"
        case updateType = "update_type"
    }
}

// MARK: - Aircraft

/// One airborne flight from AeroAPI's `/flights/search` response.
///
/// Every field is optional: which keys arrive depends on the flight, the data source, and how much
/// FlightAware knows about the airframe.
struct Aircraft: Sendable, Hashable, Decodable, Identifiable {
    // Identity
    /// FlightAware's unique per-flight identifier. The app's stable identity, replacing the ICAO
    /// hex that the ADS-B feed used to supply.
    let faFlightID: String?
    let ident: String?
    let identICAO: String?
    let identIATA: String?
    /// One or two characters: G/GG medevac, L lifeguard, A air taxi, H heavy, M medium.
    let identPrefix: String?
    /// ICAO type code where known, IATA otherwise.
    let aircraftType: String?

    // Route — free with the scan on this feed, where the ADS-B feed needed a separate lookup.
    let origin: AirportRef?
    let destination: AirportRef?

    // Position and motion
    let lastPosition: FlightPosition?

    enum CodingKeys: String, CodingKey {
        case ident, origin, destination
        case faFlightID = "fa_flight_id"
        case identICAO = "ident_icao"
        case identIATA = "ident_iata"
        case identPrefix = "ident_prefix"
        case aircraftType = "aircraft_type"
        case lastPosition = "last_position"
    }

    // MARK: Identity helpers

    /// Deliberately stable rather than unique: a computed UUID would change on every access and
    /// break SwiftUI's diffing. Targets without an `fa_flight_id` are dropped during the merge.
    var id: String { faFlightID ?? callsign ?? "unidentified" }

    var callsign: String? {
        guard let trimmed = ident?.trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var displayName: String {
        callsign ?? identICAO ?? identIATA ?? "Unknown"
    }

    var typeCode: String? { aircraftType }

    /// "WMKK → YSSY", when both ends are known.
    var routeSummary: String? {
        guard let from = origin?.displayCode, let to = destination?.displayCode else { return nil }
        return "\(from) → \(to)"
    }

    /// What the `ident_prefix` code means, spelled out.
    var identPrefixLabel: String? {
        switch identPrefix?.uppercased() {
        case "G", "GG": "Medevac"
        case "L": "Lifeguard"
        case "A": "Air taxi"
        case "H": "Heavy"
        case "M": "Medium"
        default: nil
        }
    }

    // MARK: Motion

    var altBaro: BarometricAltitude? {
        guard let altitude = lastPosition?.altitude else { return nil }
        return BarometricAltitude(hundredsOfFeet: altitude)
    }

    var groundSpeed: Double? {
        lastPosition?.groundspeed.map(Double.init)
    }

    /// This feed reports a single heading rather than separate track and heading.
    var track: Double? {
        lastPosition?.heading.map(Double.init)
    }

    var verticalTrend: VerticalTrend {
        switch lastPosition?.altitudeChange?.uppercased() {
        case "C": .climbing
        case "D": .descending
        default: .level
        }
    }

    var sourceLabel: String {
        PositionSource.label(updateType: lastPosition?.updateType)
    }

    // MARK: Position

    /// The position the scope draws, or `nil` when the flight has no usable fix.
    ///
    /// - Parameter now: reference time for the position's age. Injected so merges and tests are
    ///   deterministic rather than reading the clock per call.
    func resolvedPosition(now: Date = Date()) -> ResolvedPosition? {
        guard let lastPosition,
              let latitude = lastPosition.latitude,
              let longitude = lastPosition.longitude else { return nil }

        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        guard coordinate.isValid else { return nil }

        // AeroAPI stamps each position rather than reporting an age, so age is derived. A future
        // timestamp (clock skew) reads as zero rather than as a negative age.
        let age = lastPosition.timestamp.map { max(0, now.timeIntervalSince($0)) }

        return ResolvedPosition(
            coordinate: coordinate,
            source: PositionSource(updateType: lastPosition.updateType),
            ageSeconds: age
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
