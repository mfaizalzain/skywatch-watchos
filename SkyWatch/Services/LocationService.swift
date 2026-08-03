import CoreLocation
import Foundation
import Observation

/// A location fix reduced to `Sendable` primitives at the delegate boundary.
///
/// Extracting the values here rather than passing `CLLocation` across the hop keeps the code
/// correct under strict concurrency regardless of how the SDK annotates CoreLocation's classes.
struct LocationFix: Sendable, Hashable {
    let coordinate: Coordinate
    let horizontalAccuracy: Double
    let timestamp: Date
}

/// The three numbers we need from `CLHeading`, carried across the hop as plain values.
struct HeadingSample: Sendable, Hashable {
    let trueHeading: Double
    let magneticHeading: Double
    let headingAccuracy: Double
}

@MainActor
@Observable
final class LocationService {
    private(set) var authorization: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var fix: LocationFix?
    /// Low-pass filtered true (or magnetic) heading in degrees, or `nil` when unavailable.
    private(set) var heading: Double?
    private(set) var isUpdatingLocation = false
    private(set) var isUpdatingHeading = false

    /// Called on the main actor whenever a new fix arrives. `CLLocationManager` already filters to
    /// 250 m of movement, so every callback here is a meaningful one.
    var onFix: (@MainActor (LocationFix) -> Void)?

    private let manager = CLLocationManager()
    private var delegate: LocationDelegate?

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// §4: work under reduced accuracy, but say so and suggest a wider radius.
    var hasReducedAccuracy: Bool {
        accuracyAuthorization == .reducedAccuracy
    }

    var headingAvailable: Bool { CLLocationManager.headingAvailable() }

    init() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization

        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Re-query only when the user has actually moved. A 20 nm radius does not care about 50 m.
        manager.distanceFilter = 250

        let delegate = LocationDelegate(
            onFix: { [weak self] fix in
                Task { @MainActor in self?.received(fix) }
            },
            onHeading: { [weak self] sample in
                Task { @MainActor in self?.received(sample) }
            },
            onAuthorization: { [weak self] status, accuracy in
                Task { @MainActor in self?.received(status, accuracy) }
            }
        )
        self.delegate = delegate
        manager.delegate = delegate
    }

    // MARK: - Authorisation

    /// Requested lazily, on the first scan — not at launch.
    func requestAuthorizationIfNeeded() {
        guard authorization == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    // MARK: - Location updates

    func startUpdatingLocation() {
        requestAuthorizationIfNeeded()
        guard !isUpdatingLocation else { return }
        isUpdatingLocation = true
        manager.startUpdatingLocation()
    }

    func stopUpdatingLocation() {
        guard isUpdatingLocation else { return }
        isUpdatingLocation = false
        manager.stopUpdatingLocation()
    }

    // MARK: - Heading

    /// Started only while the radar is on screen, and stopped the moment it isn't — the compass is
    /// one of the more expensive sensors to leave running.
    func startUpdatingHeading() {
        guard headingAvailable, !isUpdatingHeading else { return }
        isUpdatingHeading = true
        manager.startUpdatingHeading()
    }

    func stopUpdatingHeading() {
        guard isUpdatingHeading else { return }
        isUpdatingHeading = false
        manager.stopUpdatingHeading()
        heading = nil
    }

    // MARK: - Delegate results

    private func received(_ fix: LocationFix) {
        self.fix = fix
        onFix?(fix)
    }

    private func received(_ sample: HeadingSample) {
        // Prefer true north; fall back to magnetic; if neither is usable the radar goes north-up.
        let raw: Double?
        if sample.headingAccuracy >= 0, sample.trueHeading >= 0 {
            raw = sample.trueHeading
        } else if sample.magneticHeading >= 0 {
            raw = sample.magneticHeading
        } else {
            raw = nil
        }

        guard let raw else {
            heading = nil
            return
        }
        heading = Geodesy.lowPassHeading(previous: heading, sample: raw)
    }

    private func received(_ status: CLAuthorizationStatus, _ accuracy: CLAccuracyAuthorization) {
        authorization = status
        accuracyAuthorization = accuracy

        if isAuthorized, isUpdatingLocation {
            manager.startUpdatingLocation()
        }
    }
}

/// Holds only immutable `@Sendable` closures, so it is safe to hand to `CLLocationManager` without
/// knowing which queue it will call back on. Declared at file scope so it does not inherit
/// `LocationService`'s main-actor isolation.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let onFix: @Sendable (LocationFix) -> Void
    private let onHeading: @Sendable (HeadingSample) -> Void
    private let onAuthorization: @Sendable (CLAuthorizationStatus, CLAccuracyAuthorization) -> Void

    init(
        onFix: @escaping @Sendable (LocationFix) -> Void,
        onHeading: @escaping @Sendable (HeadingSample) -> Void,
        onAuthorization: @escaping @Sendable (CLAuthorizationStatus, CLAccuracyAuthorization) -> Void
    ) {
        self.onFix = onFix
        self.onHeading = onHeading
        self.onAuthorization = onAuthorization
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onFix(LocationFix(
            coordinate: Coordinate(location.coordinate),
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        ))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        onHeading(HeadingSample(
            trueHeading: newHeading.trueHeading,
            magneticHeading: newHeading.magneticHeading,
            headingAccuracy: newHeading.headingAccuracy
        ))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization(manager.authorizationStatus, manager.accuracyAuthorization)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Transient failures are expected indoors; the store keeps showing the last good scan and
        // the next fix resolves it. Nothing to escalate.
    }

    /// Suppresses the calibration HUD — a wrist-worn compass recalibrates constantly and the system
    /// prompt is more disruptive than the drift it fixes.
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }
}
