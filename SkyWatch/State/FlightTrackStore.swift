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

    // MARK: AeroAPI official-status layer (optional — needs a build-injected key)

    /// Official status from FlightAware, when the layer is active.
    private(set) var aeroStatus: AeroStatus?
    /// Arrival terminal at the destination, when FlightAware knows it.
    private(set) var terminal: String?
    /// Arrival gate, when FlightAware knows it.
    private(set) var gate: String?
    /// Estimated/scheduled gate arrival, when known.
    private(set) var officialArrival: Date?
    /// A human-readable problem with the AeroAPI layer (bad key, no quota…).
    private(set) var aeroError: String?
    /// Set when the landed alert fires: polling stops (the pickup job is done)
    /// but the final state stays on screen until the user clears it.
    private(set) var hasAutoStopped = false

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
    /// Non-nil only when the build has an AeroAPI key injected.
    private let aeroClient: AeroAPIClient?
    private let logger = Logger(subsystem: "com.fmz.skywatch", category: "flight-track")

    private var pollTask: Task<Void, Never>?
    private var isActive = false
    /// AeroAPI is metered — poll it at a fifth of the live cadence. 12
    /// queries/hour ≈ $0.06, trivially inside the feeder's $10/mo allowance.
    private var lastAeroPoll: Date?

    init(
        client: AirplanesLiveClient = AirplanesLiveClient(),
        notifier: FlightNotifier = FlightNotifier(),
        aeroClient: AeroAPIClient? = AeroAPIClient.hasConfiguredKey ? AeroAPIClient() : nil
    ) {
        self.client = client
        self.notifier = notifier
        self.aeroClient = aeroClient
    }

    // MARK: - Lifecycle

    /// Driven by `scenePhase`, mirroring `ScanStore` — no polling off-screen.
    /// After an auto-stop (landed) the flag stays set, so returning to the
    /// foreground does not resurrect polling for a finished pickup.
    func setActive(_ active: Bool) {
        isActive = active
        if active, flightNumber != nil, !hasAutoStopped {
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
        self.aeroStatus = nil
        self.terminal = nil
        self.gate = nil
        self.officialArrival = nil
        self.aeroError = nil
        self.lastAeroPoll = nil
        self.hasAutoStopped = false
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
        aeroStatus = nil
        terminal = nil
        gate = nil
        officialArrival = nil
        aeroError = nil
        hasAutoStopped = false
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

        // AeroAPI is metered: refresh at most once per five minutes, and only
        // when a key is present in the build.
        if aeroClient != nil, lastAeroPoll == nil || Date().timeIntervalSince(lastAeroPoll!) >= 300 {
            await refreshAero(flightNumber: flightNumber)
        }

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

    /// Official status from FlightAware. Called on a 5-minute cadence; never
    /// blanks the live layer on a transient failure (the last good state stays
    /// on screen, and the scan loop owns the error banner).
    private func refreshAero(flightNumber: FlightNumber) async {
        guard let aeroClient else { return }
        lastAeroPoll = Date()

        do {
            let flight = try await aeroClient.flight(ident: flightNumber.callsign)
            try Task.checkCancellation()
            guard flightNumber == self.flightNumber else { return }

            guard let flight else {
                // No upcoming flight found — leave the last known state up.
                return
            }
            aeroStatus = flight.phase
            terminal = flight.destination?.terminal
            gate = flight.destination?.gate
            officialArrival = flight.gateArrival
            aeroError = nil

            // Official landed beats the feed-based inference: FlightAware
            // knows the flight has arrived even if the transponder is already
            // off and the aircraft has left the ADS-B feed.
            if flight.phase.hasLanded {
                fireAlertsIfNeeded(isLanded: true)
            }
        } catch is CancellationError {
            // Loop is tearing down — nothing to do.
        } catch let failure as AeroAPIError {
            switch failure {
            case .unauthorized:
                aeroError = "Invalid FlightAware key"
            case .notFound:
                aeroError = "Flight not found on FlightAware"
            case .rateLimited:
                aeroError = "FlightAware quota reached"
            default:
                aeroError = "FlightAware unavailable"
            }
            logger.warning("AeroAPI poll failed: \(String(describing: failure), privacy: .public)")
        } catch {
            aeroError = "FlightAware unavailable"
            logger.warning("AeroAPI poll failed: \(error.localizedDescription)")
        }
    }

    private func fireAlertsIfNeeded(isLanded: Bool) {
        let eta: Double?
        if case let .inAir(etaMinutes) = phase { eta = etaMinutes } else { eta = nil }
        guard let alert = alertState.update(etaMinutes: eta, isLanded: isLanded) else { return }
        guard let flightNumber else { return }
        // Vibrate immediately — the landed buzz matters even if the user has
        // notification sounds muted, and a strong haptic cuts through on
        // wrist-down. The notification itself follows for a persistent alert.
        switch alert {
        case .landed:
            Haptics.flightLanded()
        case .thirtyMinutes, .fifteenMinutes:
            Haptics.flightMilestone()
        }
        Task { await notifier.fire(alert, flight: flightNumber.callsign) }

        // Landed is the end of the pickup job: stop polling so nothing keeps
        // hitting the APIs, but leave the final state on screen. The user
        // clears it with Stop Tracking or starts a new flight.
        if alert == .landed {
            hasAutoStopped = true
            stopPolling()
        }
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
