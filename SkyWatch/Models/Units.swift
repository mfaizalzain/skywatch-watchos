import Foundation

/// The single user setting that drives every numeric readout in the app.
enum UnitSystem: String, CaseIterable, Sendable, Identifiable, Codable {
    case aviation
    case metric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aviation: "nm · ft · kt"
        case .metric: "km · m · km/h"
        }
    }
}

/// A number and its unit kept apart so views can style them differently — the value gets the
/// primary weight, the unit stays quiet.
struct FormattedValue: Sendable, Hashable {
    let value: String
    let unit: String

    var combined: String { "\(value) \(unit)" }

    /// What VoiceOver should say. "4 nautical miles" beats "4 nm".
    let spoken: String

    init(value: String, unit: String, spoken: String? = nil) {
        self.value = value
        self.unit = unit
        self.spoken = spoken ?? "\(value) \(unit)"
    }
}

enum Units {
    static let metresPerFoot = 0.3048
    static let kilometresPerNauticalMile = 1.852

    // MARK: - Distance

    static func distance(nauticalMiles: Double, system: UnitSystem) -> FormattedValue {
        switch system {
        case .aviation:
            let value = decimal(nauticalMiles, places: nauticalMiles < 10 ? 1 : 0)
            return FormattedValue(value: value, unit: "nm", spoken: "\(value) nautical miles")
        case .metric:
            let km = nauticalMiles * kilometresPerNauticalMile
            let value = decimal(km, places: km < 10 ? 1 : 0)
            return FormattedValue(value: value, unit: "km", spoken: "\(value) kilometres")
        }
    }

    // MARK: - Altitude

    static func altitude(feet: Double, system: UnitSystem) -> FormattedValue {
        switch system {
        case .aviation:
            let value = grouped(feet)
            return FormattedValue(value: value, unit: "ft", spoken: "\(value) feet")
        case .metric:
            let metres = feet * metresPerFoot
            let value = grouped(metres)
            return FormattedValue(value: value, unit: "m", spoken: "\(value) metres")
        }
    }

    static func altitude(_ altitude: BarometricAltitude, system: UnitSystem) -> FormattedValue {
        switch altitude {
        case .onGround:
            return FormattedValue(value: "GND", unit: "", spoken: "on the ground")
        case .feet(let feet):
            return self.altitude(feet: Double(feet), system: system)
        }
    }

    // MARK: - Speed

    static func speed(knots: Double, system: UnitSystem) -> FormattedValue {
        switch system {
        case .aviation:
            let value = grouped(knots)
            return FormattedValue(value: value, unit: "kt", spoken: "\(value) knots")
        case .metric:
            let kmh = knots * kilometresPerNauticalMile
            let value = grouped(kmh)
            return FormattedValue(value: value, unit: "km/h", spoken: "\(value) kilometres per hour")
        }
    }

    // MARK: - Vertical rate

    static func verticalRate(feetPerMinute: Double, system: UnitSystem) -> FormattedValue {
        switch system {
        case .aviation:
            let value = grouped(feetPerMinute)
            return FormattedValue(value: value, unit: "ft/min", spoken: "\(value) feet per minute")
        case .metric:
            let metresPerSecond = feetPerMinute * metresPerFoot / 60
            let value = decimal(metresPerSecond, places: 1)
            return FormattedValue(value: value, unit: "m/s", spoken: "\(value) metres per second")
        }
    }

    // MARK: - Angles, temperature, time

    static func bearing(_ degrees: Double) -> FormattedValue {
        let value = String(format: "%03.0f", Geodesy.normalized0to360(degrees))
        return FormattedValue(value: value, unit: "°", spoken: "bearing \(Int(Geodesy.normalized0to360(degrees))) degrees")
    }

    static func temperature(celsius: Double) -> FormattedValue {
        let value = decimal(celsius, places: 0)
        return FormattedValue(value: value, unit: "°C", spoken: "\(value) degrees celsius")
    }

    /// Compact relative age: "12s", "4m", "2h". Used for stale positions and last-updated stamps.
    static func age(seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        return "\(Int((seconds / 3600).rounded()))h"
    }

    // MARK: - Formatting primitives

    private static func decimal(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(max(0, places))f", value)
    }

    private static func grouped(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return Int(value.rounded()).formatted(.number.grouping(.automatic))
    }
}
