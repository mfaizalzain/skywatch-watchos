import Foundation

/// Response envelope for `GET /flights/{ident}`.
struct AeroFlightResponse: Decodable, Sendable {
    let flights: [AeroFlight]
}

/// One flight record from FlightAware AeroAPI. Only the fields the Track tab
/// needs are decoded; the response carries ~80 more.
struct AeroFlight: Decodable, Sendable, Equatable {
    let ident: String
    let faFlightID: String
    let status: String
    let operatorICAO: String?
    let aircraftType: String?
    /// Gate departure (scheduled / estimated / actual).
    let scheduledOut: Date?
    /// Runway departure (scheduled / estimated / actual).
    let scheduledOff: Date?
    /// Runway arrival (scheduled / estimated / actual).
    let scheduledOn: Date?
    let estimatedOn: Date?
    let actualOn: Date?
    /// Gate arrival — what a picker-up actually cares about.
    let scheduledIn: Date?
    let estimatedIn: Date?
    let actualIn: Date?
    let progressPercent: Int?
    let origin: AeroAirport?
    let destination: AeroAirport?

    enum CodingKeys: String, CodingKey {
        case ident
        case faFlightID = "fa_flight_id"
        case status
        case operatorICAO = "operator_icao"
        case aircraftType = "aircraft_type"
        case scheduledOut = "scheduled_out"
        case scheduledOff = "scheduled_off"
        case scheduledOn = "scheduled_on"
        case estimatedOn = "estimated_on"
        case actualOn = "actual_on"
        case scheduledIn = "scheduled_in"
        case estimatedIn = "estimated_in"
        case actualIn = "actual_in"
        case progressPercent = "progress_percent"
        case origin
        case destination
    }

    /// The gate arrival time to display and schedule against: actual beats
    /// estimated beats scheduled. Runway arrival is the fallback.
    var gateArrival: Date? {
        actualIn ?? estimatedIn ?? scheduledIn ?? actualOn ?? estimatedOn ?? scheduledOn
    }

    /// The departure time used for "which occurrence is this" logic: gate
    /// departure, falling back to runway departure. Deliberately distinct
    /// from `gateArrival` — the two anchor opposite ends of the flight.
    var departure: Date? {
        scheduledOut ?? scheduledOff
    }

    /// Machine-readable phase derived from the human-readable `status` string.
    var phase: AeroStatus {
        AeroStatus.parse(status)
    }
}

/// Arrival airport reference (`destination`), with the gate the picker-up
/// meets at.
struct AeroAirport: Decodable, Sendable, Equatable {
    /// "ICAO/IATA/LID code or string indicating the location where tracking
    /// of the flight began/ended" — for scheduled flights this is the IATA
    /// code; for position-only flights it can be an ICAO or LID code.
    let code: String?
    /// The unambiguous IATA code when the response carries one.
    let codeIATA: String?
    let name: String?
    let city: String?
    let terminal: String?
    let gate: String?

    enum CodingKeys: String, CodingKey {
        case code
        case codeIATA = "code_iata"
        case name
        case city
        case terminal
        case gate
    }

    /// The IATA code when we can be sure it is one (three letters); falls
    /// back to the generic `code` field.
    var iataCode: String? {
        if let codeIATA, codeIATA.count == 3 { return codeIATA }
        if let code, code.count == 3, code == code.uppercased() { return code }
        return nil
    }

    /// Compact display label: code preferred, city fallback, e.g. "KUL".
    var displayLabel: String {
        iataCode ?? city ?? code ?? "—"
    }
}

/// The small set of flight states the Track tab distinguishes. `parse` is a
/// prefix match because AeroAPI's `status` is a free-form summary string
/// ("Arrived / Gate Arrival", "En Route", …).
enum AeroStatus: String, Sendable, Equatable {
    case scheduled
    case departed
    case enRoute
    case landed
    case arrived
    case cancelled
    case diverted
    case unknown

    static func parse(_ raw: String) -> AeroStatus {
        let value = raw.lowercased()
        if value.contains("scheduled") { return .scheduled }
        if value.contains("departed") { return .departed }
        if value.contains("en route") { return .enRoute }
        if value.contains("landed") { return .landed }
        if value.contains("arrived") { return .arrived }
        if value.contains("cancel") { return .cancelled }
        if value.contains("divert") { return .diverted }
        return .unknown
    }

    /// Whether a picker-up should head to the gate now.
    var hasLanded: Bool {
        self == .landed || self == .arrived
    }

    /// Whether the flight is still to come (not yet departed).
    var isUpcoming: Bool {
        self == .scheduled
    }
}

/// Picks the flight to track out of the response list.
///
/// `GET /flights/{ident}` returns ~14 days of history and future occurrences
/// ordered by `scheduled_out` descending — so `flights.first` is the *furthest
/// future*, which is useless for a pickup. The caller is meeting a flight, so
/// the right target is the occurrence whose departure is closest to now:
/// an en-route flight wins over tonight's scheduled one, which wins over
/// tomorrow's. Flights that are cancelled or diverted are never picked.
enum AeroFlightPicker {
    static func pick(from response: AeroFlightResponse, now: Date = Date()) -> AeroFlight? {
        // A flight is "current" if it departed within the last 12 hours or is
        // still ahead — i.e. airborne, on the ground, or scheduled nearby.
        // Anything older is history.
        let candidates = response.flights.filter { flight in
            guard flight.phase != .cancelled, flight.phase != .diverted else { return false }
            guard let departure = flight.departure else { return false }
            return departure >= now.addingTimeInterval(-12 * 3600)
        }
        // Closest departure to now wins: an en-route flight (departed an hour
        // ago) beats tonight's scheduled one, which beats tomorrow's. Arrived
        // flights keep their scheduled departure, so one that landed this
        // morning is still a candidate — a pickup alert is exactly right.
        return candidates.min { a, b in
            let aDelta = abs((a.departure ?? .distantPast).timeIntervalSince(now))
            let bDelta = abs((b.departure ?? .distantPast).timeIntervalSince(now))
            return aDelta < bDelta
        }
    }
}
