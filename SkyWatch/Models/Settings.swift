import Foundation
import Observation

/// The radii the Digital Crown snaps through.
enum ScanRadius: Double, CaseIterable, Sendable, Identifiable, Codable {
    case five = 5
    case ten = 10
    case twenty = 20
    case fifty = 50

    var id: Double { rawValue }
    var nauticalMiles: Double { rawValue }

    /// The next step out, for the "Widen to 50 nm" action on the empty state.
    var wider: ScanRadius? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    static func nearest(to value: Double) -> ScanRadius {
        allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .twenty
    }
}

enum RefreshInterval: Int, CaseIterable, Sendable, Identifiable, Codable {
    case fast = 10
    case normal = 20
    case relaxed = 60

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var title: String { "\(rawValue)s" }

    /// Migrates a stored raw value from the pre-sweet-spot cadence (5/10/30 s)
    /// to the new one, preserving the user's *intent* rather than the literal
    /// number: fast stays fast, normal stays normal, relaxed stays relaxed.
    /// New values pass through untouched.
    static func migrated(from stored: Int?) -> RefreshInterval {
        switch stored {
        case 5: .fast
        case 10: .normal
        case 30: .relaxed
        default: stored.flatMap(RefreshInterval.init(rawValue:)) ?? .normal
        }
    }
}

/// User settings, persisted to the shared App Group defaults so the widget reads the same values.
///
/// Stored properties rather than `@AppStorage`: `ScanStore` reacts to a radius change from outside
/// any view, and `@Observable` only tracks stored properties — computed accessors over
/// `UserDefaults` would persist correctly but never notify SwiftUI. Each setter mirrors to the
/// shared suite, which is also what makes the widget see the same values.
@MainActor
@Observable
final class SettingsStore {
    static let appGroupIdentifier = SharedStore.appGroupIdentifier

    @ObservationIgnored private let defaults: UserDefaults

    var radius: ScanRadius {
        didSet { defaults.set(radius.rawValue, forKey: Key.radius) }
    }

    var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval) }
    }

    var unitSystem: UnitSystem {
        didSet { defaults.set(unitSystem.rawValue, forKey: Key.unitSystem) }
    }

    var isHeadingUp: Bool {
        didSet { defaults.set(isHeadingUp, forKey: Key.headingUp) }
    }

    var hidesGroundTraffic: Bool {
        didSet { defaults.set(hidesGroundTraffic, forKey: Key.hideGroundTraffic) }
    }

    var showsMilitaryOnly: Bool {
        didSet { defaults.set(showsMilitaryOnly, forKey: Key.militaryOnly) }
    }

    /// MLAT and receiver-estimated targets. On by default — in thin coverage they are most of what
    /// there is to see, and they are clearly badged wherever they appear.
    var includesUncertainTargets: Bool {
        didSet { defaults.set(includesUncertainTargets, forKey: Key.includeUncertainTargets) }
    }

    var hapticAlertsEnabled: Bool {
        didSet { defaults.set(hapticAlertsEnabled, forKey: Key.hapticAlerts) }
    }

    var pinnedHexes: Set<String> {
        didSet { defaults.set(Array(pinnedHexes).sorted(), forKey: Key.pinned) }
    }

    init(defaults: UserDefaults? = nil) {
        let store = defaults ?? UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
        self.defaults = store

        radius = (store.object(forKey: Key.radius) as? Double).flatMap(ScanRadius.init(rawValue:)) ?? .twenty
        refreshInterval = RefreshInterval.migrated(from: store.object(forKey: Key.refreshInterval) as? Int)
        unitSystem = (store.string(forKey: Key.unitSystem)).flatMap(UnitSystem.init(rawValue:)) ?? .aviation
        isHeadingUp = store.object(forKey: Key.headingUp) as? Bool ?? true
        hidesGroundTraffic = store.object(forKey: Key.hideGroundTraffic) as? Bool ?? true
        showsMilitaryOnly = store.object(forKey: Key.militaryOnly) as? Bool ?? false
        includesUncertainTargets = store.object(forKey: Key.includeUncertainTargets) as? Bool ?? true
        hapticAlertsEnabled = store.object(forKey: Key.hapticAlerts) as? Bool ?? false
        pinnedHexes = Set(store.stringArray(forKey: Key.pinned) ?? [])
    }

    func isPinned(_ hex: String) -> Bool { pinnedHexes.contains(hex) }

    func togglePin(_ hex: String) {
        if pinnedHexes.contains(hex) {
            pinnedHexes.remove(hex)
        } else {
            pinnedHexes.insert(hex)
        }
    }

    private enum Key {
        static let radius = "radiusNM"
        static let refreshInterval = "refreshInterval"
        static let unitSystem = "unitSystem"
        static let headingUp = "headingUp"
        static let hideGroundTraffic = "hideGroundTraffic"
        static let militaryOnly = "militaryOnly"
        static let includeUncertainTargets = "includeUncertainTargets"
        static let hapticAlerts = "hapticAlerts"
        static let pinned = "pinnedHexes"
    }
}
