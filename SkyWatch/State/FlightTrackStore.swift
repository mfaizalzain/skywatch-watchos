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
    /// The one store for the whole app, shared with the Siri / Shortcuts
    /// intents so "track flight MH123" lands in the same tab the UI shows.
    static let shared = FlightTrackStore()

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
    /// Notification permission as last observed. Surfaced in the Track UI so
    /// a denied permission — which silently disables screen-off alerts — is
    /// visible instead of mysteriously "not working".
    private(set) var notificationPermission: NotificationPermission = .unknown

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
    /// Scheduled departure time from FlightAware (when the layer is active).
    /// Answers "has this flight left yet?" for the searching / not-found
    /// states, which otherwise cannot tell "not departed" from "out of
    /// coverage".
    private(set) var scheduledDeparture: Date?
    /// How far along the route the flight is, from FlightAware (0–100).
    private(set) var progressPercent: Int?
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

    /// When the flight is due to arrive, derived from the live ETA measured at
    /// the last poll. Nil until both position and ground speed are known.
    var estimatedArrival: Date? {
        guard case let .inAir(etaMinutes) = phase, let etaMinutes, etaMinutes.isFinite else { return nil }
        return (lastUpdated ?? Date()).addingTimeInterval(etaMinutes * 60)
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
            // A scheduled alert may have fired while the app was suspended
            // (that's the whole point of scheduling) — fold it into the alert
            // state BEFORE the first poll so the UI and the live path don't
            // fire it a second time, and stop polling outright if the flight
            // has already landed.
            Task {
                await reconcileDeliveredAlerts()
                // The flight may have landed while we were suspended: check
                // FlightAware's official status on the very next poll instead
                // of waiting out the 10-minute metered cadence.
                lastAeroPoll = nil
                guard isActive, flightNumber != nil, !hasAutoStopped else { return }
                startPolling()
            }
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
        self.scheduledDeparture = nil
        self.progressPercent = nil
        self.aeroError = nil
        self.lastAeroPoll = nil
        self.hasAutoStopped = false
        // Drop any alerts armed for a previous flight so they can't fire later.
        if let previousCallsign {
            Task { await notifier.cancelAll(for: previousCallsign) }
        }
        Task {
            await notifier.requestAuthorizationIfNeeded()
            await refreshNotificationPermission()
        }
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
        scheduledDeparture = nil
        progressPercent = nil
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

        // A scheduled alert may have fired since the last poll (e.g. it came
        // due while the screen was on and the delegate presented it). Fold any
        // delivered alerts into the state so the live path below doesn't fire
        // the same milestone a second time, and stop outright if the flight
        // has landed.
        await reconcileDeliveredAlerts()
        guard flightNumber == self.flightNumber else { return }
        // A delivered landed alert ended the pickup job — nothing left to poll.
        guard !hasAutoStopped else { return }

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
            scheduledDeparture = flight.departure
            progressPercent = flight.progressPercent
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

    /// Arms the not-yet-fired pickup alerts as future-dated local
    /// notifications (they fire from the notification system even when the
    /// app is suspended — the pickup-wait case). The decisions — which
    /// milestones to arm, and for when — live in
    /// `FlightAlertState.scheduledAlerts`; this method only hands the plans to
    /// the notification center.
    ///
    /// Called on every poll that knows an ETA: each call replaces the previous
    /// schedule with one built from the freshest numbers, so the alerts track
    /// the flight rather than drifting with an old ETA. A heads-up is armed
    /// only while its threshold is still *ahead* of the current ETA: once the
    /// ETA is inside the window the instant-fire path owns the alert on this
    /// same poll, and the two paths can't both deliver — a live fire cancels
    /// its scheduled twin (shared identifier) first.
    private func rearmScheduledAlerts(etaMinutes: Double?) {
        guard let flightNumber else { return }
        let now = Date()
        for plan in alertState.scheduledAlerts(
            etaMinutes: etaMinutes,
            officialArrival: officialArrival,
            now: now
        ) {
            // Only the landed body carries the terminal/gate suffix.
            let detail = plan.alert == .landed ? arrivalDetail : nil
            Task { await notifier.schedule(plan.alert, flight: flightNumber.callsign, at: plan.fireAt, detail: detail) }
        }
    }

    /// " at gate B12" / " at terminal 1", for the landed notification body.
    private var arrivalDetail: String? {
        if let gate { return " at gate \(gate)" }
        if let terminal { return " at terminal \(terminal)" }
        return nil
    }

    /// Marks any alert that fired from the notification system while the app
    /// was suspended as fired, so returning to the app doesn't replay it. A
    /// delivered landed alert also ends the pickup job: the flight has landed,
    /// so polling should stop even before the next live poll confirms it.
    private func reconcileDeliveredAlerts() async {
        guard let flightNumber else { return }
        let delivered = await notifier.deliveredAlerts(flightNumber.callsign)
        guard !delivered.isEmpty else { return }
        var state = alertState
        for alert in delivered { state.markFired(alert) }
        alertState = state
        if delivered.contains(.landed) {
            hasAutoStopped = true
            stopPolling()
        }
    }

    /// Reads the current notification permission so the Track UI can tell the
    /// user when screen-off alerts are impossible (denied) before they rely on
    /// them.
    func refreshNotificationPermission() async {
        notificationPermission = await notifier.permissionStatus()
    }

    private func fireAlertsIfNeeded(isLanded: Bool) {
        // Landed is the end of the pickup job regardless of whether the landed
        // alert is new or already fired (e.g. a scheduled notification that
        // fired while the app was suspended): stop polling so nothing keeps
        // hitting the APIs, but leave the final state on screen. The user
        // clears it with Stop Tracking or starts a new flight.
        if isLanded {
            hasAutoStopped = true
            stopPolling()
        }

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
        // identifier), and any *less urgent* armed milestone is now
        // meaningless — the 15-minute alert must not leave a "30 minutes"
        // notification behind to fire later.
        Task { await notifier.cancel(alert, flight: flightNumber.callsign) }
        switch alert {
        case .landed:
            Task { await notifier.cancel(.thirtyMinutes, flight: flightNumber.callsign) }
            Task { await notifier.cancel(.fifteenMinutes, flight: flightNumber.callsign) }
        case .fifteenMinutes:
            Task { await notifier.cancel(.thirtyMinutes, flight: flightNumber.callsign) }
        case .thirtyMinutes:
            break
        }
        Task { await notifier.fire(alert, flight: flightNumber.callsign, detail: arrivalDetail) }
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
    /// Current notification permission (for the Track UI's permission hint).
    var permissionStatus: @Sendable () async -> NotificationPermission = {
        await FlightNotifier.defaultPermissionStatus()
    }
    /// Which of the three alerts are sitting in the delivered-notification
    /// center for a flight — i.e. fired from the system while we were
    /// suspended. Used on foreground to fold them into the alert state.
    var deliveredAlerts: @Sendable (String) async -> [FlightAlert] = { flight in
        await FlightNotifier.defaultDeliveredAlerts(flight: flight)
    }
    var fireAlert: @Sendable (FlightAlert, String, String?) async -> Void = { alert, flight, detail in
        await FlightNotifier.defaultFire(alert, flight: flight, detail: detail)
    }
    var scheduleAlert: @Sendable (FlightAlert, String, Date, String?) async -> Void = { alert, flight, at, detail in
        await FlightNotifier.defaultSchedule(alert, flight: flight, at: at, detail: detail)
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

    /// Fires immediately. `detail` is an optional " at gate B12" suffix for
    /// the landed alert's body.
    func fire(_ alert: FlightAlert, flight: String, detail: String? = nil) async {
        await fireAlert(alert, flight, detail)
    }

    /// Arms a future-dated alert: the notification system delivers it even if
    /// the app is backgrounded or suspended, so a pickup alert still fires
    /// while the watch sits on the charger.
    func schedule(_ alert: FlightAlert, flight: String, at date: Date, detail: String? = nil) async {
        await scheduleAlert(alert, flight, date, detail)
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

    private static func defaultPermissionStatus() async -> NotificationPermission {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        default:
            return .unknown
        }
    }

    private static func defaultDeliveredAlerts(flight: String) async -> [FlightAlert] {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let prefix = "flight-alert-\(flight)-"
        return delivered.compactMap { notification in
            let id = notification.request.identifier
            guard id.hasPrefix(prefix) else { return nil }
            return FlightAlert(rawValue: String(id.dropFirst(prefix.count)))
        }
    }

    private static func defaultFire(_ alert: FlightAlert, flight: String, detail: String?) async {
        let content = UNMutableNotificationContent()
        content.title = "\(flight) — \(alert.rawValue)"
        content.body = alert.body(detail: detail)
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

    private static func defaultSchedule(_ alert: FlightAlert, flight: String, at date: Date, detail: String?) async {
        let content = UNMutableNotificationContent()
        content.title = "\(flight) — \(alert.rawValue)"
        content.body = alert.body(detail: detail)
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

    /// Notification body with an arrival detail (terminal/gate) appended where
    /// it matters. `detail` is the "at gate B12"-style suffix; the 30/15
    /// heads-ups ignore it.
    func body(detail: String?) -> String {
        switch self {
        case .landed:
            if let detail {
                return "Flight has landed\(detail). Go pick them up!"
            }
            return body
        default:
            return body
        }
    }
}
