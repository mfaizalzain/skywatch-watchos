import CoreLocation
import Foundation

/// A plain, `Sendable` latitude/longitude pair.
///
/// `CLLocationCoordinate2D` is a C struct whose `Sendable` status has shifted between SDKs, so the
/// app carries its own value type across concurrency boundaries and converts at the MapKit /
/// CoreLocation boundary only.
struct Coordinate: Sendable, Hashable, Codable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Rejects out-of-range values that occasionally appear in malformed feed data.
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && latitude >= -90 && latitude <= 90
            && longitude >= -180 && longitude <= 180
    }
}

enum VerticalTrend: Sendable, Hashable {
    case climbing
    case level
    case descending
}

/// Result of projecting a target forward along its current track.
struct ClosestApproach: Sendable, Hashable {
    /// Seconds until the minimum distance is reached. Zero when the target is already receding.
    let timeToClosestApproach: TimeInterval
    let minimumDistanceNM: Double
}

/// Pure great-circle helpers. Everything here is a free function of its inputs so it can be
/// exercised without a device, a location fix, or a network.
enum Geodesy {
    static let metresPerNauticalMile: Double = 1852

    // MARK: - Distance and bearing

    static func distanceNM(from origin: Coordinate, to destination: Coordinate) -> Double {
        let a = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let b = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        return a.distance(from: b) / metresPerNauticalMile
    }

    /// Great-circle forward azimuth, normalised to 0..<360.
    static func initialBearing(from origin: Coordinate, to destination: Coordinate) -> Double {
        let phi1 = origin.latitude.radians
        let phi2 = destination.latitude.radians
        let deltaLambda = (destination.longitude - origin.longitude).radians

        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)

        // atan2(0, 0) is 0 rather than undefined, which is the answer we want for a zero-length leg.
        return normalized0to360(atan2(y, x).degrees)
    }

    /// Where to draw a target when the scope is heading-up rather than north-up.
    static func relativeBearing(absolute: Double, deviceHeading: Double) -> Double {
        normalized0to360(absolute - deviceHeading)
    }

    // MARK: - Angles

    /// Maps any angle onto 0..<360. Exactly 360 wraps to 0, so 359.9 -> 0.0 never produces 360.
    static func normalized0to360(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    /// Signed shortest angular distance from `a` to `b`, in -180...180.
    static func angularDifference(from a: Double, to b: Double) -> Double {
        let raw = normalized0to360(b - a)
        return raw > 180 ? raw - 360 : raw
    }

    /// Low-pass filter for compass headings.
    ///
    /// Filtering the raw degrees would make a 359 -> 1 step average to 180 — pointing the sweep line
    /// backwards. Filtering the sine and cosine components crosses the wrap correctly.
    static func lowPassHeading(previous: Double?, sample: Double, alpha: Double = 0.15) -> Double {
        guard let previous else { return normalized0to360(sample) }
        let clampedAlpha = min(max(alpha, 0), 1)
        let sinComponent = sin(previous.radians) * (1 - clampedAlpha) + sin(sample.radians) * clampedAlpha
        let cosComponent = cos(previous.radians) * (1 - clampedAlpha) + cos(sample.radians) * clampedAlpha

        // Both components collapse to zero only for exactly-opposed inputs at alpha 0.5; hold the
        // previous value rather than emitting an arbitrary direction.
        guard sinComponent != 0 || cosComponent != 0 else { return normalized0to360(previous) }
        return normalized0to360(atan2(sinComponent, cosComponent).degrees)
    }

    // MARK: - Vertical

    /// ±64 ft/min dead band so that a level cruise doesn't flicker between climb and descent.
    static func verticalTrend(baroRate: Double?, deadBand: Double = 64) -> VerticalTrend {
        guard let baroRate, baroRate.isFinite else { return .level }
        if baroRate > deadBand { return .climbing }
        if baroRate < -deadBand { return .descending }
        return .level
    }

    // MARK: - Closest point of approach

    /// Projects the target forward along `track` at `groundSpeedKt` and returns when it will be
    /// nearest the observer. This is the "look up in 40 seconds" number.
    ///
    /// Uses a flat local projection centred on the observer, which is accurate well beyond the
    /// 250 nm the API allows.
    static func closestPointOfApproach(
        target: Coordinate,
        trackDegrees: Double?,
        groundSpeedKt: Double?,
        observer: Coordinate
    ) -> ClosestApproach? {
        guard let trackDegrees, let groundSpeedKt, groundSpeedKt > 0,
              target.isValid, observer.isValid else { return nil }

        let nmPerDegreeLatitude = 60.0
        let nmPerDegreeLongitude = 60.0 * cos(observer.latitude.radians)

        // Relative position of the target, in nautical miles east/north of the observer.
        var deltaLongitude = target.longitude - observer.longitude
        if deltaLongitude > 180 { deltaLongitude -= 360 }
        if deltaLongitude < -180 { deltaLongitude += 360 }

        let x = deltaLongitude * nmPerDegreeLongitude
        let y = (target.latitude - observer.latitude) * nmPerDegreeLatitude

        // Velocity in nm per second.
        let speed = groundSpeedKt / 3600
        let vx = speed * sin(trackDegrees.radians)
        let vy = speed * cos(trackDegrees.radians)

        let speedSquared = vx * vx + vy * vy
        guard speedSquared > 0 else { return nil }

        // t* minimising |r + vt| is -(r·v)/|v|². Negative means the closest pass already happened.
        let time = max(0, -(x * vx + y * vy) / speedSquared)
        let closestX = x + vx * time
        let closestY = y + vy * time

        return ClosestApproach(
            timeToClosestApproach: time,
            minimumDistanceNM: (closestX * closestX + closestY * closestY).squareRoot()
        )
    }
}

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
