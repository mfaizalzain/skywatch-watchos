import Foundation
import Observation
import WidgetKit
import os

/// Single source of truth for the whole app: where we are, what is overhead, and what went wrong.
@MainActor
@Observable
final class ScanStore {
    // MARK: Published state

    private(set) var targets: [TrackedTarget] = []
    /// Targets heard on Mode S with no position at all — excluded from the scope, counted here.
    private(set) var positionlessCount = 0
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    private(set) var error: SkyWatchError?

    let settings: SettingsStore
    let location: LocationService

    /// Set from the view hierarchy's `\.isLuminanceReduced`. Drives the Always-On polling back-off.
    var isLuminanceReduced = false {
        didSet {
            guard oldValue != isLuminanceReduced, isPolling else { return }
            // Re-arm the loop so a wrist-down doesn't wait out a full 10 s cycle before backing off,
            // and a wrist-raise doesn't wait out a full 60 s one before catching up.
            restartPolling()
        }
    }

    // MARK: Dependencies

    private let client: AirplanesLiveClient
    private let merger = TargetMerger()
    private let logger = Logger(subsystem: "com.fmz.skywatch", category: "scan")

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isPolling = false

    /// Where we were standing when the last query went out, for the 250 m movement rule.
    private var lastQueryCoordinate: Coordinate?
    private var lastWidgetReload: Date?

    // MARK: Init

    init(
        settings: SettingsStore = SettingsStore(),
        location: LocationService = LocationService(),
        client: AirplanesLiveClient = AirplanesLiveClient()
    ) {
        self.settings = settings
        self.location = location
        self.client = client

        location.onFix = { [weak self] fix in
            self?.locationDidUpdate(fix)
        }
    }

    // MARK: - Derived state

    /// Filtered and ordered exactly as both the list and the scope want it: pinned first, then by
    /// distance. Sorting once here keeps the two views honest about showing the same thing.
    var visibleTargets: [TrackedTarget] {
        let pinned = settings.pinnedHexes
        return targets
            .filter { passesFilters($0) }
            .sorted { lhs, rhs in
                let lhsPinned = pinned.contains(lhs.id)
                let rhsPinned = pinned.contains(rhs.id)
                if lhsPinned != rhsPinned { return lhsPinned }
                return lhs.distanceNM < rhs.distanceNM
            }
    }

    var nearest: TrackedTarget? {
        visibleTargets.min(by: { $0.distanceNM < $1.distanceNM })
    }

    /// Stands in for the CoreLocation fix. Only previews and tests set it; on device it stays nil.
    var injectedObserver: Coordinate?

    var observerCoordinate: Coordinate? { injectedObserver ?? location.fix?.coordinate }

    /// How stale the data on screen is. Shown whenever a refresh has failed.
    var dataAge: TimeInterval? {
        guard let lastUpdated else { return nil }
        return Date().timeIntervalSince(lastUpdated)
    }

    var hasEverLoaded: Bool { lastUpdated != nil }

    private func passesFilters(_ target: TrackedTarget) -> Bool {
        if settings.showsMilitaryOnly, !target.aircraft.isMilitary { return false }
        if settings.hidesGroundTraffic, target.aircraft.altBaro?.isOnGround == true { return false }
        if !settings.includesUncertainTargets, !target.position.source.isPrecise { return false }
        if target.distanceNM > settings.radius.nauticalMiles * 1.05 { return false }
        return true
    }

    // MARK: - Lifecycle

    /// Driven by `scenePhase`. Nothing polls while the app is not on screen — no exceptions.
    func setActive(_ active: Bool) {
        if active {
            location.startUpdatingLocation()
            startPolling()
        } else {
            stopPolling()
            location.stopUpdatingLocation()
            location.stopUpdatingHeading()
        }
    }

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let interval = self.currentInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stopPolling() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        isLoading = false
    }

    /// Wrist down means nobody is looking. One request a minute is enough to keep the scope warm.
    private var currentInterval: TimeInterval {
        isLuminanceReduced ? 60 : settings.refreshInterval.seconds
    }

    // MARK: - Refresh

    /// Coalesced refresh: while one scan is in flight, further calls are no-ops rather than queueing
    /// up behind the rate limiter and arriving as a stale burst.
    ///
    /// - Parameter force: replace the in-flight scan instead of skipping. Used when the radius
    ///   changed, which makes the request already on the wire the wrong request.
    func refresh(force: Bool = false) async {
        if let existing = refreshTask {
            guard force else { return }
            existing.cancel()
            await existing.value
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    /// Used by the Digital Crown. Radius changes arrive per tick; only the last one is worth a
    /// request, so the query waits 400 ms for the crown to settle.
    func refreshAfterSettling() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.refresh(force: true)
        }
    }

    private func performRefresh() async {
        location.requestAuthorizationIfNeeded()

        if location.isDenied {
            error = .locationDenied
            return
        }

        guard let observer = observerCoordinate else {
            // Not an error yet on a cold start — the first fix is usually seconds away.
            if hasEverLoaded == false, location.isAuthorized == false {
                error = nil
            } else if location.isAuthorized {
                error = .locationUnavailable
            }
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await client.aircraft(
                near: observer,
                radiusNM: settings.radius.nauticalMiles
            )
            try Task.checkCancellation()
            apply(response, observer: observer)
            error = nil
        } catch is CancellationError {
            // Scene deactivated or the radius changed underneath us. Leave the screen as it is.
        } catch let failure as SkyWatchError {
            // The last good scan stays on screen with a visible age. Never blank on a transient.
            error = failure
            logger.error("Scan failed: \(String(describing: failure), privacy: .public)")
        } catch {
            self.error = .decoding(underlying: error.localizedDescription)
        }
    }

    private func apply(_ response: AircraftResponse, observer: Coordinate) {
        let now = Date()
        targets = merger.merge(existing: targets, response: response.aircraft, observer: observer, now: now)
        positionlessCount = response.aircraft.filter(\.isPositionless).count
        lastUpdated = now
        lastQueryCoordinate = observer

        fireProximityAlertsIfNeeded()
        publishSnapshot()
    }

    /// One-off lookup for the detail screen. Shares the client — and therefore the rate limiter —
    /// with the scan loop, so the two can never combine to exceed one request per second.
    func refreshDetail(hex: String) async -> Aircraft? {
        do {
            let response = try await client.aircraft(hex: hex)
            guard let aircraft = response.aircraft.first(where: { $0.hex == hex }) else { return nil }

            // Fold the fresher data back into the scan so the list and scope agree with the detail
            // screen instead of drifting apart while it is open.
            if let observer = observerCoordinate {
                targets = merger.merge(
                    existing: targets,
                    response: [aircraft],
                    observer: observer,
                    penalizeMissing: false
                )
            }
            return aircraft
        } catch {
            // The scan loop owns the error banner; a failed detail poll just leaves the last values
            // on screen.
            return nil
        }
    }

    // MARK: - Location changes

    private func locationDidUpdate(_ fix: LocationFix) {
        guard isPolling else { return }
        guard let previous = lastQueryCoordinate else {
            Task { await refresh() }
            return
        }

        // CoreLocation's 250 m distance filter already thinned these out; this second check covers
        // the case where the filter delivers a fix that is only marginally different.
        let movedMetres = Geodesy.distanceNM(from: previous, to: fix.coordinate) * Geodesy.metresPerNauticalMile
        if movedMetres > 250 {
            Task { await refresh() }
        }
    }

    // MARK: - Alerts

    /// One buzz per aircraft per session, and only for something genuinely overhead. An app that
    /// vibrates continuously under an approach path gets deleted.
    private func fireProximityAlertsIfNeeded() {
        guard settings.hapticAlertsEnabled else { return }

        for index in targets.indices {
            let target = targets[index]
            guard !target.hasAlerted else { continue }
            guard target.distanceNM < 3 else { continue }
            guard let feet = target.aircraft.altBaro?.feetValue, feet < 8_000 else { continue }
            guard target.position.source.isPrecise, !target.position.isStale else { continue }

            targets[index].hasAlerted = true
            Haptics.proximityAlert()
        }
    }

    // MARK: - Widget

    private func publishSnapshot() {
        let visible = visibleTargets
        let nearestTarget = visible.min(by: { $0.distanceNM < $1.distanceNM })

        let snapshot = ScanSnapshot(
            capturedAt: Date(),
            radiusNM: settings.radius.nauticalMiles,
            count: visible.count,
            nearest: nearestTarget.map { target in
                ScanSnapshot.NearestSummary(
                    callsign: target.aircraft.displayName,
                    distanceNM: target.distanceNM,
                    altitudeFeet: target.aircraft.altBaro?.feetValue,
                    isOnGround: target.aircraft.altBaro?.isOnGround ?? false,
                    bearingDegrees: target.bearingDegrees
                )
            }
        )
        SharedStore.save(snapshot)

        // Reloading the timeline on every 10 s scan would burn the widget's refresh budget for no
        // benefit — the complication is a glance, not a live feed.
        let now = Date()
        if let last = lastWidgetReload, now.timeIntervalSince(last) <= 600 { return }
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// Deliberately NOT DEBUG-gated: `#Preview` bodies are compiled in Release too,
// and five view files reference previewStore from their previews. Keeping this
// available in all configs keeps Release builds compiling; the fixture code is
// inert outside Xcode previews.
extension ScanStore {
    /// Seeds a store with fixtures so previews exercise the real views rather than stand-ins.
    /// Defined here because `targets` and friends are `private(set)` to this file.
    static func previewStore(
        targets: [TrackedTarget] = [],
        error: SkyWatchError? = nil,
        hasLoaded: Bool = true,
        isLuminanceReduced: Bool = false
    ) -> ScanStore {
        let store = ScanStore(
            settings: SettingsStore(defaults: UserDefaults(suiteName: "com.fmz.skywatch.preview") ?? .standard)
        )
        store.targets = targets
        store.error = error
        store.lastUpdated = hasLoaded ? Date().addingTimeInterval(-8) : nil
        store.isLuminanceReduced = isLuminanceReduced
        store.injectedObserver = PreviewData.observer
        return store
    }
}
