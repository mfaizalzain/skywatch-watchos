import Foundation

/// The last scan, flattened to the few values a complication can show.
///
/// Deliberately tiny: this crosses into the widget extension, which gets a fraction of the app's
/// memory budget and needs to decode it during a timeline reload.
struct ScanSnapshot: Codable, Sendable, Hashable {
    let capturedAt: Date
    let radiusNM: Double
    let count: Int
    let nearest: NearestSummary?

    struct NearestSummary: Codable, Sendable, Hashable {
        let callsign: String
        let distanceNM: Double
        let altitudeFeet: Int?
        let isOnGround: Bool
        let bearingDegrees: Double
    }

    var age: TimeInterval { Date().timeIntervalSince(capturedAt) }

    /// Placeholder content for the widget gallery and for a first run that has never scanned.
    static let placeholder = ScanSnapshot(
        capturedAt: .now,
        radiusNM: 20,
        count: 3,
        nearest: NearestSummary(
            callsign: "UAL328",
            distanceNM: 4.2,
            altitudeFeet: 12_000,
            isOnGround: false,
            bearingDegrees: 210
        )
    )

    static let empty = ScanSnapshot(capturedAt: .now, radiusNM: 20, count: 0, nearest: nil)
}

/// The App Group container shared by the app and the widget.
///
/// The app writes after every successful foreground scan; the widget only ever reads. The widget
/// does not call the API itself — see the note in `SkyWatchWidget`.
enum SharedStore {
    /// Declared here rather than on `SettingsStore` so this file compiles into the widget target
    /// without dragging the whole observable settings object along with it.
    static let appGroupIdentifier = "group.com.fmz.skywatch"
    private static let snapshotKey = "lastScanSnapshot"

    /// The unit setting, read straight from the shared suite. The widget has no `SettingsStore`.
    static var unitSystem: UnitSystem {
        UnitSystem(rawValue: defaults.string(forKey: "unitSystem") ?? "") ?? .aviation
    }

    /// Falls back to the standard suite when the App Group is unavailable — on a free personal team
    /// the app still works, the complication just can't see the app's scans.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func save(_ snapshot: ScanSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func load() -> ScanSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(ScanSnapshot.self, from: data)
    }
}
