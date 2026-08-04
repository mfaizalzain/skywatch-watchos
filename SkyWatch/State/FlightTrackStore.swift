import Foundation
import Observation
import UserNotifications
import os

/// Drives the Track Flight tab: polls a flight's callsign, computes the ETA to
/// the chosen arrival airport, and fires the 30 / 15 / landed alerts.
///
/// Polling policy matches the rest of the app (see `ScanStore`): nothing runs
/// while the app is not on screen. Keep the Track screen up (Always-On
/// display) and the alerts fire as thresholds are crossed.
@MainActor
@Observable
final class FlightTrackStore {
    // MARK: Published state

    private(set) var phase: FlightPhase = .idle
    private(set) var flightNumber: FlightNumber?
    private(set) var airport: Airport?
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    private(set) var error: SkyWatchError?
    private(set) var alertState = FlightAlertState()
    /// Distance from the aircraft's last known position to the airport (NM).
    private(set) var distanceNM: Double?

    /// Set from `\.isLuminanceReduced`; backs the poll loop off on wrist-down.
    var isLuminanceReduced = false {
        didSet {
            guard oldValue != isLuminanceReduced, pollTask != nil else { return }
            restartPolling()
        }
    }

    // MARK: Dependencies

    private let client: AirplanesLiveClient
    private let notifier: FlightNotifier
    private let logger = Logger(subsystem: "com.fmz.skywatch", category: "flight-track")

    private var pollTask: Task<Void, Never>?
    private var isActive = false

    init(client: AirplanesLiveClient = AirplanesLiveClient(), notifier: FlightNotifier = FlightNotifier()) {
        self.client = client
        self.notifier = notifier
    }

    // MARK: - Lifecycle

    /// Driven by `scenePhase`, mirroring `ScanStore` — no polling off-screen.
    func setActive(_ active: Bool) {
        isActive = active
        if active, flightNumber != nil {
            startPolling()
        } else {
            stopPolling()
        }
    }

    /// Begins tracking. `airport` is the arrival airport (pickup point).
    func startTracking(number: FlightNumber, airport: Airport) {
        self.flightNumber = number
        self.airport = airport
        self.phase = .searching
        self.alertState = FlightAlertState()
        self.distanceNM = nil
        self.error = nil
        Task { await notifier.requestAuthorizationIfNeeded() }
        if isActive { startPolling() }
    }

    func stopTracking() {
        stopPolling()
        flightNumber = nil
        airport = nil
        phase = .idle
        alertState = FlightAlertState()
        distanceNM = nil
        error = nil
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.isLuminanceReduced ? 60 : 30))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func restartPolling() {
        guard pollTask != nil else { return }
        startPolling()
    }

    private func refresh() async {
        guard let flightNumber, let airport else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await client.aircraft(callsign: flightNumber.callsign)
            try Task.checkCancellation()
            guard flightNumber == self.flightNumber, airport == self.airport else { return }

            if let message = response.apiError {
                error = .apiMessage(message)
                return
            }

            guard let aircraft = response.aircraft.first else {
                // Not in the feed: either never airborne, out of coverage, or
                // powered down after landing. If we were tracking it and it was
                // near the airport, treat the disappearance as landed.
                if case .inAir = phase {
                    phase = FlightTracker.isLandedAfterDisappearance(lastDistanceNM: distanceNM) ? .disappeared : .notFound
                } else {
                    phase = .notFound
                }
                lastUpdated = Date()
                fireAlertsIfNeeded(isLanded: phase == .disappeared)
                return
            }

            lastUpdated = Date()
            let distance = Self.distance(from: aircraft, to: airport)
            distanceNM = distance

            if aircraft.altBaro == .onGround {
                phase = .onGround(distanceNM: distance)
                fireAlertsIfNeeded(isLanded: distance <= FlightTracker.landedDistanceNM)
                return
            }

            // Airborne: ETA from distance + ground speed.
            let eta = aircraft.groundSpeed.flatMap {
                FlightTracker.etaMinutes(distanceNM: distance, groundSpeedKnots: $0)
            }
            phase = .inAir(etaMinutes: eta)
            fireAlertsIfNeeded(isLanded: false)

        } catch is CancellationError {
            // Task was cancelled — nothing to log, the loop is tearing down.
        } catch let failure as SkyWatchError {
            error = failure
            logger.warning("Poll failed: \(String(describing: failure), privacy: .public)")
        } catch let other {
            self.error = .decoding(underlying: other.localizedDescription)
            logger.warning("Poll failed: \(other.localizedDescription)")
        }
    }

    private func fireAlertsIfNeeded(isLanded: Bool) {
        let eta: Double?
        if case let .inAir(etaMinutes) = phase { eta = etaMinutes } else { eta = nil }
        guard let alert = alertState.update(etaMinutes: eta, isLanded: isLanded) else { return }
        guard let flightNumber else { return }
        Task { await notifier.fire(alert, flight: flightNumber.callsign) }
    }

    // MARK: - Helpers

    private static func distance(from aircraft: Aircraft, to airport: Airport) -> Double {
        guard let lat = aircraft.lat, let lon = aircraft.lon else { return .infinity }
        return Geodesy.distanceNM(
            from: Coordinate(latitude: lat, longitude: lon),
            to: airport.coordinate
        )
    }
}

/// Thin wrapper around `UNUserNotificationCenter` so the store stays testable.
struct FlightNotifier: Sendable {
    var requestAuthorization: @Sendable () async -> Bool = { await FlightNotifier.defaultRequest() }
    var fireAlert: @Sendable (FlightAlert, String) async -> Void = { alert, flight in
        await FlightNotifier.defaultFire(alert, flight: flight)
    }

    func requestAuthorizationIfNeeded() async {
        _ = await requestAuthorization()
    }

    func fire(_ alert: FlightAlert, flight: String) async {
        await fireAlert(alert, flight)
    }

    private static func defaultRequest() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    private static func defaultFire(_ alert: FlightAlert, flight: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(flight) — \(alert.rawValue)"
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "flight-alert-\(flight)-\(alert.rawValue)",
            content: content,
            trigger: nil // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension FlightAlert {
    var body: String {
        switch self {
        case .thirtyMinutes: "Flight lands in about 30 minutes. Time to head out."
        case .fifteenMinutes: "Flight lands in about 15 minutes."
        case .landed: "Flight has landed. Go pick them up!"
        }
    }
}
