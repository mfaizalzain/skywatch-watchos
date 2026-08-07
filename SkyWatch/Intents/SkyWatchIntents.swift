import AppIntents
import Foundation

/// "What's overhead?" — triggers an immediate scan of the radar.
struct ScanNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan for nearby aircraft"
    static let description = IntentDescription("Refreshes SkyWatch's radar immediately.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await ScanStore.shared.refresh()
        return .result()
    }
}

/// "Track the nearest flight" — hands the closest aircraft with a parseable
/// flight number to the Track tab. Parameterless because the watchOS metadata
/// exporter only supports AppEntity/AppEnum-typed parameters; an arbitrary
/// flight number stays a typed-in (or picked-from-the-list) flow.
struct TrackNearestFlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Track the nearest flight"
    static let description = IntentDescription("Starts pickup tracking for the closest aircraft with a flight number.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let scan = ScanStore.shared
        let target = scan.visibleTargets
            .filter { $0.aircraft.callsign.flatMap(FlightNumber.parse) != nil }
            .min(by: { $0.distanceNM < $1.distanceNM })

        guard let target, let callsign = target.aircraft.callsign, let number = FlightNumber.parse(callsign) else {
            // Nothing trackable overhead — just open the app.
            return .result()
        }
        FlightTrackStore.shared.startTracking(number: number)
        return .result()
    }
}

/// Siri / Shortcuts phrases for the app. Discovery is automatic on watchOS.
struct SkyWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanNowIntent(),
            phrases: [
                "Scan for aircraft with \(.applicationName)",
                "What's overhead with \(.applicationName)"
            ],
            shortTitle: "Scan for aircraft",
            systemImageName: "airplane"
        )
        AppShortcut(
            intent: TrackNearestFlightIntent(),
            phrases: [
                "Track the nearest flight with \(.applicationName)"
            ],
            shortTitle: "Track nearest flight",
            systemImageName: "location.fill"
        )
    }
}
