import Foundation

// MARK: - Altitude

/// `alt_baro` is an integer altitude in feet, or the literal string `"ground"`.
enum BarometricAltitude: Sendable, Hashable, Decodable {
    case feet(Int)
    case onGround

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let feet = try? container.decode(Int.self) {
            self = .feet(feet)
            return
        }
        if let feet = try? container.decode(Double.self) {
            self = .feet(Int(feet.rounded()))
            return
        }

        let text = try container.decode(String.self)
        guard text.caseInsensitiveCompare("ground") == .orderedSame else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised alt_baro value \"\(text)\""
            )
        }
        self = .onGround
    }

    var feetValue: Int? {
        if case .feet(let feet) = self { return feet }
        return nil
    }

    var isOnGround: Bool { self == .onGround }
}

// MARK: - Flags

/// `dbFlags` is a bitfield, not an enumeration.
struct DatabaseFlags: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let military = DatabaseFlags(rawValue: 1)
    static let interesting = DatabaseFlags(rawValue: 2)
    /// Privacy ICAO Address — the hex is rotated and does not identify the airframe.
    static let pia = DatabaseFlags(rawValue: 4)
    /// Limiting Aircraft Data Displayed — the operator asked to be filtered from public feeds.
    static let ladd = DatabaseFlags(rawValue: 8)
}

// MARK: - Status

enum Emergency: String, Sendable, Hashable, CaseIterable {
    case none
    case general
    case lifeguard
    case minfuel
    case nordo
    case unlawful
    case downed
    case reserved

    var isActive: Bool { self != .none }

    var label: String {
        switch self {
        case .none: "None"
        case .general: "General emergency"
        case .lifeguard: "Lifeguard"
        case .minfuel: "Minimum fuel"
        case .nordo: "No radio"
        case .unlawful: "Unlawful interference"
        case .downed: "Downed aircraft"
        case .reserved: "Reserved"
        }
    }
}

/// How the position we are about to draw was obtained.
enum PositionSource: Sendable, Hashable {
    /// A real position report — ADS-B, TIS-B or ADS-C.
    case reported
    /// Multilateration. Real, but with accuracy that varies with receiver geometry.
    case mlat
    /// Receiver-estimated (`rr_lat`/`rr_lon`). Not a fix, and must never be presented as one.
    case estimated

    var isPrecise: Bool { self == .reported }
}

/// A position the UI can actually draw, together with everything it needs to qualify it.
struct ResolvedPosition: Sendable, Hashable {
    let coordinate: Coordinate
    let source: PositionSource
    /// Seconds since the position was measured, when the feed tells us.
    let ageSeconds: TimeInterval?

    /// §2 rule 5: a target is fresh only while its position is under a minute old.
    var isStale: Bool { (ageSeconds ?? 0) >= 60 }

    /// Estimated positions are always uncertain; MLAT and stale fixes are worth a caution badge.
    var needsCaution: Bool { source != .reported || isStale }
}

// MARK: - Aircraft

/// One aircraft from the `ac` array.
///
/// Every field is optional: the feed omits keys rather than sending nulls, and which keys arrive
/// depends on the airframe, the transponder version, and which receiver heard it.
struct Aircraft: Sendable, Hashable, Decodable, Identifiable {
    // Identity
    let hex: String?
    let flight: String?
    let registration: String?
    let typeCode: String?
    let category: String?
    let dbFlagsRaw: Int?

    // Position and motion
    let lat: Double?
    let lon: Double?
    let altBaro: BarometricAltitude?
    let altGeom: Double?
    let groundSpeed: Double?
    let indicatedAirspeed: Double?
    let trueAirspeed: Double?
    let mach: Double?
    let track: Double?
    let baroRate: Double?
    let geomRate: Double?
    let trueHeading: Double?
    let magHeading: Double?
    let roll: Double?

    // Status
    let squawk: String?
    let emergencyRaw: String?
    let alert: Int?
    let spi: Int?
    let navModes: [String]?
    let navAltitudeMCP: Double?
    let navQNH: Double?

    // Freshness and source
    let seen: Double?
    let seenPos: Double?
    let rssi: Double?
    let sourceType: String?
    let lastPosition: LastPosition?
    let receiverLat: Double?
    let receiverLon: Double?

    // Derived extras
    let windDirection: Double?
    let windSpeed: Double?
    let outsideAirTemperature: Double?
    let totalAirTemperature: Double?

    // Quality
    let nic: Int?
    let rc: Int?
    let nacP: Int?
    let nacV: Int?
    let sil: Int?
    let silType: String?
    let gva: Int?
    let sda: Int?
    let version: Int?

    enum CodingKeys: String, CodingKey {
        case hex, flight, category, lat, lon, mach, track, roll, squawk, alert, spi, seen, rssi
        case nic, rc, sil, gva, sda, version
        case registration = "r"
        case typeCode = "t"
        case dbFlagsRaw = "dbFlags"
        case altBaro = "alt_baro"
        case altGeom = "alt_geom"
        case groundSpeed = "gs"
        case indicatedAirspeed = "ias"
        case trueAirspeed = "tas"
        case baroRate = "baro_rate"
        case geomRate = "geom_rate"
        case trueHeading = "true_heading"
        case magHeading = "mag_heading"
        case emergencyRaw = "emergency"
        case navModes = "nav_modes"
        case navAltitudeMCP = "nav_altitude_mcp"
        case navQNH = "nav_qnh"
        case seenPos = "seen_pos"
        case sourceType = "type"
        case lastPosition
        case receiverLat = "rr_lat"
        case receiverLon = "rr_lon"
        case windDirection = "wd"
        case windSpeed = "ws"
        case outsideAirTemperature = "oat"
        case totalAirTemperature = "tat"
        case nacP = "nac_p"
        case nacV = "nac_v"
        case silType = "sil_type"
    }

    // MARK: Identity helpers

    /// Stable identity. The `~` prefix is part of the address and is kept here; it is stripped only
    /// for display.
    /// Deliberately stable rather than unique: a computed UUID would change on every access and
    /// break SwiftUI's diffing. Targets without a hex are dropped during the merge anyway.
    var id: String { hex ?? callsign ?? registration ?? "unidentified" }

    /// A leading `~` marks a non-ICAO address (TIS-B, ADS-R). Not something to show the user.
    var displayHex: String? {
        guard let hex else { return nil }
        return hex.hasPrefix("~") ? String(hex.dropFirst()) : hex
    }

    var isNonICAOAddress: Bool { hex?.hasPrefix("~") ?? false }

    /// `flight` is space-padded to eight characters on the wire.
    var callsign: String? {
        guard let trimmed = flight?.trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// What to put on a row when there is no callsign — registration, then hex, then nothing useful.
    var displayName: String {
        callsign ?? registration ?? displayHex?.uppercased() ?? "Unknown"
    }

    var flags: DatabaseFlags { DatabaseFlags(rawValue: dbFlagsRaw ?? 0) }
    var isMilitary: Bool { flags.contains(.military) }

    var emergency: Emergency {
        guard let emergencyRaw, let value = Emergency(rawValue: emergencyRaw.lowercased()) else {
            return .none
        }
        return value
    }

    /// 7500 hijack, 7600 radio failure, 7700 general emergency.
    var hasEmergencySquawk: Bool {
        guard let squawk else { return false }
        return ["7500", "7600", "7700"].contains(squawk)
    }

    var isAlerting: Bool { emergency.isActive || hasEmergencySquawk }

    var navModeList: [String] { navModes ?? [] }

    var verticalTrend: VerticalTrend {
        Geodesy.verticalTrend(baroRate: baroRate ?? geomRate)
    }

    // MARK: Position

    /// §2 rules 1–4, resolved once so that no view has to re-derive them.
    ///
    /// Returns `nil` for `mode_s` targets and anything else we heard but cannot place — those are
    /// excluded from the radar and belong under "Heard, no position".
    var resolvedPosition: ResolvedPosition? {
        let source: PositionSource = (sourceType == "mlat") ? .mlat : .reported

        if let lat, let lon {
            let coordinate = Coordinate(latitude: lat, longitude: lon)
            if coordinate.isValid {
                return ResolvedPosition(coordinate: coordinate, source: source, ageSeconds: seenPos)
            }
        }

        // Rule 1: the top-level position aged out, but the feed kept the last one it had.
        if let lastPosition, let lat = lastPosition.lat, let lon = lastPosition.lon {
            let coordinate = Coordinate(latitude: lat, longitude: lon)
            if coordinate.isValid {
                return ResolvedPosition(
                    coordinate: coordinate,
                    source: source,
                    // Anything arriving via lastPosition is by definition over a minute old.
                    ageSeconds: lastPosition.seenPos ?? 60
                )
            }
        }

        // Rule 2: no fix at all — only the rough position of the receiver that heard it.
        if let receiverLat, let receiverLon {
            let coordinate = Coordinate(latitude: receiverLat, longitude: receiverLon)
            if coordinate.isValid {
                return ResolvedPosition(coordinate: coordinate, source: .estimated, ageSeconds: seen)
            }
        }

        return nil
    }

    /// Rule 4: heard on Mode S with no position information whatsoever.
    var isPositionless: Bool { resolvedPosition == nil }
}

/// Present when the top-level `lat`/`lon` are more than 60 s old.
struct LastPosition: Sendable, Hashable, Decodable {
    let lat: Double?
    let lon: Double?
    let nic: Int?
    let rc: Int?
    let seenPos: Double?

    enum CodingKeys: String, CodingKey {
        case lat, lon, nic, rc
        case seenPos = "seen_pos"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
