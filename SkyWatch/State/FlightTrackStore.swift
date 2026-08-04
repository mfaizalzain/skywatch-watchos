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
    /// Route: departure airport → destination airport, e.g. "SIN → KUL".
    /// Built from FlightAware's origin/destination; nil without the layer.
    private(set) var route: String?
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

    /// Begins tracking. `airport` may be nil when FlightAware is expected to
    /// auto-detect the destination from its own data; until it is known the
    /// live ETA is unavailable (it needs the destination's coordinates).
    func startTracking(number: FlightNumber, airport: Airport? = nil) {
        let previousCallsign = self.flightNumber?.callsign
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
        self.route = nil
        self.aeroError = nil
        self.lastAeroPoll = nil
        self.hasAutoStopped = false
        // Drop any alerts armed for a previous flight so they can't fire later.
        if let previousCallsign {
            Task { await notifier.cancelAll(for: previousCallsign) }
        }
        Task { await notifier.requestAuthorizationIfNeeded() }
        if isActive { startPolling() }
    }

    func stopTracking() {
        if let flightNumber {
            Task { await notifier.cancelAll(for: flightNumber.callsign) }
        }
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
        route = nil
        aeroError = nil
        hasAutoStopped = false
    }

    /// Sets the arrival airport mid-tracking — the fallback when FlightAware
    /// could not resolve the destination (no key in the build, or the
    /// destination is not in the airport catalog). The next poll computes
    /// distance and ETA against it.
    func selectAirport(_ airport: Airport) {
        guard self.airport == nil else { return }
        self.airport = airport
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Tracking is a wait, not a live radar: a flight's ETA doesn't
                // meaningfully change faster than this, and every skipped poll
                // saves battery. 2 min on wrist-up, 5 min on wrist-down.
                try? await Task.sleep(for: .seconds(self.isLuminanceReduced ? 300 : 120))
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
        guard let flightNumber else { return }
        isLoading = true
        defer { isLoading = false }

        // AeroAPI is metered: refresh at most once per ten minutes, and only
        // when a key is present in the build. Runs even before the arrival
        // airport is known — resolving the destination is how the airport is
        // auto-detected.
        if aeroClient != nil, lastAeroPoll == nil || Date().timeIntervalSince(lastAeroPoll!) >= 600 {
            await refreshAero(flightNumber: flightNumber)
        }

        // The live ETA needs the destination's coordinates. Until the airport
        // is known (auto-detected from FlightAware, or chosen by the user)
        // there is nothing to measure against.
        guard let airport else {
            phase = .searching
            return
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
            rearmScheduledAlerts(etaMinutes: eta)
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
            route = Self.routeLabel(origin: flight.origin, destination: flight.destination)
            aeroError = nil

            // Auto-detect the arrival airport from FlightAware's destination
            // when the user hasn't chosen one: the destination code resolves
            // against the airport catalog, which carries the coordinates the
            // live ETA needs. If the destination is not in the catalog the
            // picker remains the way in.
            if airport == nil, let code = flight.destination?.iataCode,
               let found = Airport.find(iata: code) {
                airport = found
            }

            // Re-arm the landed alert from the official gate arrival, and the
            // 30/15 from whatever the live layer knows — so all three fire
            // even if the app is suspended at pickup time.
            var eta: Double?
            if case let .inAir(etaMinutes) = phase { eta = etaMinutes }
            rearmScheduledAlerts(etaMinutes: eta)

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

    /// Arms the not-yet-fired 30/15-minute alerts as future-dated local
    /// notifications (they fire from the notification system even when the
    /// app is suspended — the pickup-wait case), and re-arms the landed alert
    /// from the official FlightAware arrival when known.
    ///
    /// Called on every poll that knows an ETA: each call replaces the previous
    /// schedule with one built from the freshest numbers, so the alerts track
    /// the flight rather than drifting with an old ETA. Only milestones that
    /// are genuinely ahead are armed — once the ETA crosses a threshold the
    /// instant-fire path (`fireAlertsIfNeeded`) owns it, so the two paths
    /// never race on the same alert. Milestones already fired are never
    /// re-armed.
    private func rearmScheduledAlerts(etaMinutes: Double?) {
        guard let flightNumber else { return }
        let now = Date()
        // Arm only when the milestone is at least a minute ahead, so the
        // scheduled alert and the live-crossing fire can't both deliver.
        let horizon = 1.0

        if !alertState.hasFired30, let etaMinutes, etaMinutes.isFinite, etaMinutes > 30 + horizon {
            let at = now.addingTimeInterval((etaMinutes - 30) * 60)
            Task { await notifier.schedule(.thirtyMinutes, flight: flightNumber.callsign, at: at) }
        }
        if !alertState.hasFired15, let etaMinutes, etaMinutes.isFinite, etaMinutes > 15 + horizon {
            let at = now.addingTimeInterval((etaMinutes - 15) * 60)
            Task { await notifier.schedule(.fifteenMinutes, flight: flightNumber.callsign, at: at) }
        }
        if !alertState.hasFiredLanded, let officialArrival, officialArrival > now.addingTimeInterval(60) {
            Task { await notifier.schedule(.landed, flight: flightNumber.callsign, at: officialArrival) }
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
        // A live fire supersedes the armed future-dated one (they share an
        // identifier, so this also prevents a duplicate when both paths run).
        Task { await notifier.cancel(alert, flight: flightNumber.callsign) }
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

    /// "SIN → KUL" style route label, built from FlightAware's origin and
    /// destination airport refs. Skipped if either side is unknown.
    private static func routeLabel(origin: AeroAirport?, destination: AeroAirport?) -> String? {
        guard let origin, let destination else { return nil }
        return "\(origin.displayLabel) → \(destination.displayLabel)"
    }

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
    var scheduleAlert: @Sendable (FlightAlert, String, Date) async -> Void = { alert, flight, at in
        await FlightNotifier.defaultSchedule(alert, flight: flight, at: at)
    }
    var cancelScheduled: @Sendable (FlightAlert, String) async -> Void = { alert, flight in
        await FlightNotifier.defaultCancel(alert, flight: flight)
    }
    var cancelAll: @Sendable (String) async -> Void = { flight in
        await FlightNotifier.defaultCancelAll(flight: flight)
    }

    func requestAuthorizationIfNeeded() async {
        _ = await requestAuthorization()
    }

    func fire(_ alert: FlightAlert, flight: String) async {
        await fireAlert(alert, flight)
    }

    /// Arms a future-dated alert: the notification system delivers it even if
    /// the app is backgrounded or suspended, so a pickup alert still fires
    /// while the watch sits on the charger.
    func schedule(_ alert: FlightAlert, flight: String, at date: Date) async {
        await scheduleAlert(alert, flight, date)
    }

    /// Removes a previously armed alert (re-armed with a new ETA, or fired
    /// live before its scheduled time).
    func cancel(_ alert: FlightAlert, flight: String) async {
        await cancelScheduled(alert, flight)
    }

    /// Removes every armed alert for a flight — used when tracking stops or
    /// restarts so stale notifications don't fire later.
    func cancelAll(for flight: String) async {
        await cancelAll(flight)
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

    private static func identifier(_ alert: FlightAlert, flight: String) -> String {
        "flight-alert-\(flight)-\(alert.rawValue)"
    }

    private static func defaultFire(_ alert: FlightAlert, flight: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(flight) — \(alert.rawValue)"
        content.body = alert.body
        content.sound = .default
        // Same identifier as the scheduled variant: a live fire replaces any
        // still-pending scheduled one for this milestone.
        let request = UNNotificationRequest(
            identifier: identifier(alert, flight: flight),
            content: content,
            trigger: nil // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func defaultSchedule(_ alert: FlightAlert, flight: String, at date: Date) async {
        let content = UNMutableNotificationContent()
        content.title = "\(flight) — \(alert.rawValue)"
        content.body = alert.body
        content.sound = .default
        // watchOS refuses triggers under 60 s; clamp so a caller racing the
        // clock can't produce an invalid request.
        let interval = max(date.timeIntervalSinceNow, 60)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier(alert, flight: flight),
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func defaultCancel(_ alert: FlightAlert, flight: String) async {
        await UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier(alert, flight: flight)]
        )
    }

    private static func defaultCancelAll(flight: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix("flight-alert-\(flight)-") }
        await center.removePendingNotificationRequests(withIdentifiers: identifiers)
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
