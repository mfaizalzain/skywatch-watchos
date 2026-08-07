import Foundation

/// IATA → ICAO airline-code mapping for flight-number lookup.
///
/// Users type the number printed on their boarding pass (IATA form, e.g.
/// "MH123"); the ADS-B feed identifies aircraft by ICAO callsign ("MAS123").
/// Unmapped codes fall back to trying the raw input as a callsign, so an
/// already-ICAO entry ("MAS123") works even without a mapping.
enum AirlineCodes {
    /// NOTE: dictionary literals with duplicate keys are a FATAL runtime error
    /// in Swift (Swift/Dictionary.swift:840). Keep every IATA key unique —
    /// the regional groups below intentionally do not repeat an airline.
    static let iataToIcao: [String: String] = [
        // Malaysia / Singapore region
        "MH": "MAS", "SQ": "SIA", "AK": "AXM", "QZ": "QZR", "TR": "TGW",
        "FY": "FMY", "OD": "MXD", "BI": "RBA", "GA": "GIA", "ID": "BTK",
        "JT": "LNI", "QG": "CTV", "IN": "NAM", "KD": "KAL", "MI": "SLK",
        "CX": "CPA", "KA": "HDA", "EK": "UAE", "EY": "ETD", "QR": "QTR",
        "TG": "THA", "FD": "AIA", "WE": "THD", "SL": "TLM", "VJ": "VJC",
        "BL": "PIC", "QH": "BHV", "VN": "HVN", "PR": "PAL", "5J": "CEB",
        "2P": "GAP", "DG": "SRQ", "NU": "NOK", "DD": "NOK", "BZ": "DAE",
        // East Asia
        "JL": "JAL", "NH": "ANA", "BC": "SKY", "GK": "SKY", "HD": "ADO",
        "KE": "KAL", "OZ": "AAR", "7C": "JJA", "ZE": "ESR", "CA": "CCA",
        "MU": "CES", "CZ": "CSN", "HU": "CHH", "MF": "CXA", "3U": "CSC",
        "HO": "DKH", "9C": "CQH", "SC": "CDG", "ZH": "CSZ", "CI": "CAL",
        "BR": "EVA", "AE": "MDA", "B7": "UIA",
        // Indian subcontinent
        "AI": "AIC", "6E": "IGO", "UK": "VTI", "SG": "SEJ", "9W": "JAI",
        "G8": "IGO", "PK": "PIA", "UL": "ALK",
        // Middle East
        "GF": "GFA", "KU": "KAC", "SV": "SVA", "TK": "THY", "RJ": "RJA",
        "ME": "MEA", "WY": "OMA",
        // Europe
        "BA": "BAW", "VS": "VIR", "LH": "DLH", "LX": "SWR", "OS": "AUA",
        "AF": "AFR", "KL": "KLM", "IB": "IBE", "AZ": "AZA", "TP": "TAP",
        "SK": "SAS", "AY": "FIN", "DY": "NAX", "D8": "IBK", "FR": "RYR",
        "U2": "EZY", "BE": "BEE", "SN": "BEL", "A3": "AEE", "OU": "CTN",
        "LO": "LOT", "OK": "CSA", "BT": "BTI", "SU": "AFL",
        "PS": "AUI", "RO": "ROT", "EI": "EIN", "EW": "EWG", "AB": "BER",
        // Oceania
        "QF": "QFA", "VA": "VOZ", "JQ": "JST", "NZ": "ANZ", "FJ": "FJI",
        // Americas
        "AA": "AAL", "UA": "UAL", "DL": "DAL", "AS": "ASA", "B6": "JBU",
        "WN": "SWA", "AC": "ACA", "WS": "WJA", "TS": "TSC", "AM": "AMX",
        "AV": "AVA", "LA": "LAN", "CM": "CMP", "AR": "ARG", "G3": "GLO",
        "JJ": "TAM", "HA": "HAL",
    ]

    /// The ICAO prefix for an IATA code, if mapped.
    static func icao(forIATA iata: String) -> String? {
        iataToIcao[iata.uppercased()]
    }
}

/// A parsed flight number, e.g. "MH123" (IATA) → callsign "MAS123" (ICAO).
struct FlightNumber: Equatable, Sendable {
    let raw: String
    let prefix: String
    let digits: String

    /// The ADS-B callsign this flight should be broadcasting.
    var callsign: String {
        (AirlineCodes.icao(forIATA: prefix) ?? prefix) + digits
    }

    /// Accepts "MH123", "MAS123", "mh 123", "MH-123" — anything with an
    /// alphabetic prefix (2–3 letters) followed by 1–4 digits.
    static func parse(_ input: String) -> FlightNumber? {
        let cleaned = input
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        guard let match = cleaned.wholeMatch(of: /^([A-Z]{2,3})(\d{1,4})$/) else {
            return nil
        }
        return FlightNumber(raw: cleaned, prefix: String(match.1), digits: String(match.2))
    }
}

/// What the tracked flight is doing right now.
enum FlightPhase: Equatable, Sendable {
    case idle
    case searching
    /// Airborne; `etaMinutes` is the great-circle time to the arrival airport
    /// at current ground speed, when both position and speed are known.
    case inAir(etaMinutes: Double?)
    /// Transponder reports "ground"; `distanceNM` to the arrival airport.
    case onGround(distanceNM: Double?)
    /// Was being tracked, then left the feed (powered down — typically landed).
    case disappeared
    /// Never seen in the feed (not departed, out of coverage, or wrong number).
    case notFound

    /// Whether the flight is transmitting a live position right now.
    var isLive: Bool {
        if case .inAir = self { return true }
        if case .onGround = self { return true }
        return false
    }

    /// One-line answer to "is this flight currently live?" for the status card.
    var liveLabel: String {
        switch self {
        case .idle: return "Not tracking"
        case .searching: return "Checking…"
        case .inAir: return "LIVE — in the air"
        case .onGround: return "On the ground"
        case .disappeared: return "Landed (left the feed)"
        case .notFound: return "Not live right now"
        }
    }
}

/// The three pickup milestones, each fired once per tracking session.
enum FlightAlert: String, Sendable {
    case thirtyMinutes = "30 min to landing"
    case fifteenMinutes = "15 min to landing"
    case landed = "Flight has landed"
}

/// Whether the app may schedule the screen-off pickup alerts. Surfaced in the
/// Track UI so a denied permission is visible rather than silent.
enum NotificationPermission: Equatable, Sendable {
    case unknown
    case authorized
    case denied
}

/// One-session alert bookkeeping: fires each milestone exactly once, in
/// urgency order (landed > 15 > 30) so a fast descent never skips an alert.
/// A more urgent milestone that has already fired suppresses every less urgent
/// one for the rest of the session — a flight tracked from inside the
/// 15-minute window must never later announce "30 minutes to landing".
struct FlightAlertState: Equatable, Sendable {
    private(set) var fired: Set<FlightAlert> = []

    /// Returns the alert to fire now (if any), marking it as fired.
    /// `isLanded` is the store's verdict (on-ground near the airport, or left
    /// the feed while near it); `etaMinutes` is the live ETA if known.
    mutating func update(etaMinutes: Double?, isLanded: Bool) -> FlightAlert? {
        if isLanded, !fired.contains(.landed) {
            fired.insert(.landed)
            return .landed
        }

        // The landed verdict, or an already-fired 15-minute heads-up, makes
        // the 30-minute one meaningless — never fall through to it. This is
        // what keeps a flight tracked from inside the 15-minute window from
        // announcing "30 minutes to landing" after the 15-minute alert.
        guard !fired.contains(.landed), !fired.contains(.fifteenMinutes) else { return nil }
        guard let etaMinutes, etaMinutes.isFinite else { return nil }

        if etaMinutes <= 15 {
            fired.insert(.fifteenMinutes)
            return .fifteenMinutes
        }
        if etaMinutes <= 30, !fired.contains(.thirtyMinutes) {
            fired.insert(.thirtyMinutes)
            return .thirtyMinutes
        }
        return nil
    }

    var hasFired30: Bool { fired.contains(.thirtyMinutes) }
    var hasFired15: Bool { fired.contains(.fifteenMinutes) }
    var hasFiredLanded: Bool { fired.contains(.landed) }

    /// Records that an alert fired from the notification system (while the app
    /// was suspended). Reopening the app then won't replay it.
    mutating func markFired(_ alert: FlightAlert) {
        fired.insert(alert)
    }
}

/// Pure math for the tracker — kept UI- and network-free so it can be tested.
enum FlightTracker {
    /// Minutes to arrival: great-circle distance at current ground speed.
    /// Nil when either input is missing or speed is (near) zero.
    static func etaMinutes(distanceNM: Double, groundSpeedKnots: Double) -> Double? {
        guard distanceNM.isFinite, distanceNM >= 0,
              groundSpeedKnots.isFinite, groundSpeedKnots > 1 else { return nil }
        return distanceNM / (groundSpeedKnots / 60)
    }

    /// How close counts as "at the airport" for landing detection.
    static let landedDistanceNM = 25.0

    /// A vanished flight counts as landed only if its last known position was
    /// near the arrival airport (powered down after arrival, not lost en route).
    static func isLandedAfterDisappearance(lastDistanceNM: Double?) -> Bool {
        guard let lastDistanceNM, lastDistanceNM.isFinite else { return false }
        return lastDistanceNM <= landedDistanceNM
    }
}
