import Foundation
import Testing

@Suite("Geodesy")
struct GeodesyTests {
    /// Land's End to John o' Groats — the worked example from Movable Type's great-circle notes:
    /// initial bearing 9.1198°, distance 968.9 km on a sphere.
    private let landsEnd = Coordinate(latitude: 50.06639, longitude: -5.71472)
    private let johnOGroats = Coordinate(latitude: 58.64389, longitude: -3.07000)

    @Test("Initial bearing matches the published great-circle example")
    func publishedBearing() {
        let bearing = Geodesy.initialBearing(from: landsEnd, to: johnOGroats)
        #expect(abs(bearing - 9.1198) < 0.01)
    }

    @Test("Distance matches the published example within the ellipsoid/sphere difference")
    func publishedDistance() {
        // The published 968.9 km is spherical; `CLLocation.distance` is ellipsoidal (WGS84), which
        // differs by a few tenths of a percent at this latitude. 1 % is a deliberately honest
        // tolerance rather than a fudge — the two models genuinely disagree by about that much.
        let expectedNM = 968.9 / 1.852
        let distance = Geodesy.distanceNM(from: landsEnd, to: johnOGroats)
        #expect(abs(distance - expectedNM) / expectedNM < 0.01)
    }

    @Test("Reverse bearing is not simply the forward bearing plus 180 on a great circle")
    func reverseBearing() {
        let forward = Geodesy.initialBearing(from: landsEnd, to: johnOGroats)
        let reverse = Geodesy.initialBearing(from: johnOGroats, to: landsEnd)
        // Both are valid; convergence of the meridians means they differ from an exact reciprocal.
        #expect(abs(Geodesy.angularDifference(from: forward + 180, to: reverse)) < 5)
        #expect(reverse > 180)
    }

    @Test("Zero distance yields zero distance and a defined bearing")
    func zeroDistance() {
        let point = Coordinate(latitude: 37.3349, longitude: -122.0090)
        #expect(Geodesy.distanceNM(from: point, to: point) < 0.0001)
        #expect(Geodesy.initialBearing(from: point, to: point) == 0)
    }

    @Test("Crossing the antimeridian goes east, not the long way round")
    func antimeridian() {
        let west = Coordinate(latitude: 0, longitude: 179.9)
        let east = Coordinate(latitude: 0, longitude: -179.9)

        #expect(abs(Geodesy.initialBearing(from: west, to: east) - 90) < 0.01)
        #expect(abs(Geodesy.initialBearing(from: east, to: west) - 270) < 0.01)
        // 0.2° of longitude on the equator is 12 nm, not 21,588.
        #expect(abs(Geodesy.distanceNM(from: west, to: east) - 12) < 0.5)
    }

    @Test("Bearings at the poles are well defined")
    func poles() {
        let equator = Coordinate(latitude: 0, longitude: 0)
        let northPole = Coordinate(latitude: 90, longitude: 0)
        let southPole = Coordinate(latitude: -90, longitude: 0)

        #expect(abs(Geodesy.initialBearing(from: equator, to: northPole)) < 0.01)
        #expect(abs(Geodesy.initialBearing(from: equator, to: southPole) - 180) < 0.01)
        // Everywhere is south of the north pole.
        #expect(abs(Geodesy.initialBearing(from: northPole, to: equator) - 180) < 0.01)
    }

    @Test("Bearings normalise into 0..<360", arguments: [
        (-90.0, 270.0), (0.0, 0.0), (359.9, 359.9), (360.0, 0.0), (720.0, 0.0), (-360.0, 0.0), (450.0, 90.0)
    ])
    func normalisation(input: Double, expected: Double) {
        #expect(abs(Geodesy.normalized0to360(input) - expected) < 0.0001)
    }

    @Test("Relative bearing subtracts the device heading and wraps")
    func relativeBearing() {
        #expect(Geodesy.relativeBearing(absolute: 10, deviceHeading: 350) == 20)
        #expect(Geodesy.relativeBearing(absolute: 350, deviceHeading: 10) == 340)
        #expect(Geodesy.relativeBearing(absolute: 90, deviceHeading: 90) == 0)
    }

    @Test("Angular difference is signed and takes the short way")
    func angularDifference() {
        #expect(abs(Geodesy.angularDifference(from: 350, to: 10) - 20) < 0.0001)
        #expect(abs(Geodesy.angularDifference(from: 10, to: 350) + 20) < 0.0001)
        #expect(abs(Geodesy.angularDifference(from: 0, to: 180) - 180) < 0.0001)
    }

    // MARK: - Heading filter

    @Test("The heading filter crosses 359 to 0 without spinning through 180")
    func headingWrap() {
        // Averaging the raw degrees would give 180 here — pointing the sweep line backwards.
        let filtered = Geodesy.lowPassHeading(previous: 359, sample: 1, alpha: 0.5)
        #expect(filtered < 5 || filtered > 355)

        // 350 -> 10 is a +20° step; a quarter of it is +5°, so the filter should land near 355.
        let quarter = Geodesy.lowPassHeading(previous: 350, sample: 10, alpha: 0.25)
        #expect(Geodesy.angularDifference(from: 350, to: quarter) > 0)
        #expect(Geodesy.angularDifference(from: 350, to: quarter) < 20)
    }

    @Test("The first sample is adopted outright")
    func headingFirstSample() {
        #expect(Geodesy.lowPassHeading(previous: nil, sample: 42) == 42)
        #expect(Geodesy.lowPassHeading(previous: nil, sample: -10) == 350)
    }

    @Test("A repeated sample converges rather than oscillating")
    func headingConverges() {
        var heading: Double?
        for _ in 0..<80 {
            heading = Geodesy.lowPassHeading(previous: heading, sample: 90)
        }
        #expect(abs((heading ?? 0) - 90) < 0.5)
    }

    // MARK: - Vertical trend

    @Test("The vertical dead band is ±64 ft/min", arguments: [
        (nil as Double?, VerticalTrend.level),
        (0, .level),
        (64, .level),
        (-64, .level),
        (65, .climbing),
        (-65, .descending),
        (2400, .climbing),
        (-1216, .descending)
    ])
    func verticalTrend(rate: Double?, expected: VerticalTrend) {
        #expect(Geodesy.verticalTrend(baroRate: rate) == expected)
    }

    // MARK: - Closest point of approach

    @Test("A target flying straight at you closes to zero")
    func headOnApproach() throws {
        let observer = Coordinate(latitude: 37.0, longitude: -122.0)
        // 10 nm due north, tracking south at 360 kt: 10 nm at 0.1 nm/s is 100 seconds.
        let target = Coordinate(latitude: 37.0 + 10.0 / 60.0, longitude: -122.0)

        let approach = try #require(
            Geodesy.closestPointOfApproach(
                target: target,
                trackDegrees: 180,
                groundSpeedKt: 360,
                observer: observer
            )
        )

        #expect(abs(approach.timeToClosestApproach - 100) < 2)
        #expect(approach.minimumDistanceNM < 0.2)
    }

    @Test("A receding target has already made its closest approach")
    func recedingTarget() throws {
        let observer = Coordinate(latitude: 37.0, longitude: -122.0)
        let target = Coordinate(latitude: 37.0 + 10.0 / 60.0, longitude: -122.0)

        let approach = try #require(
            Geodesy.closestPointOfApproach(
                target: target,
                trackDegrees: 0,
                groundSpeedKt: 360,
                observer: observer
            )
        )

        #expect(approach.timeToClosestApproach == 0)
        #expect(abs(approach.minimumDistanceNM - 10) < 0.2)
    }

    @Test("A crossing target's minimum distance is its offset, not zero")
    func crossingTarget() throws {
        let observer = Coordinate(latitude: 37.0, longitude: -122.0)
        // 5 nm north, tracking east: it stays 5 nm away and is already at its closest.
        let target = Coordinate(latitude: 37.0 + 5.0 / 60.0, longitude: -122.0)

        let approach = try #require(
            Geodesy.closestPointOfApproach(
                target: target,
                trackDegrees: 90,
                groundSpeedKt: 300,
                observer: observer
            )
        )

        #expect(abs(approach.minimumDistanceNM - 5) < 0.2)
    }

    @Test("No track or no speed means no projection")
    func noProjection() {
        let observer = Coordinate(latitude: 37.0, longitude: -122.0)
        let target = Coordinate(latitude: 37.1, longitude: -122.0)

        #expect(Geodesy.closestPointOfApproach(target: target, trackDegrees: nil, groundSpeedKt: 300, observer: observer) == nil)
        #expect(Geodesy.closestPointOfApproach(target: target, trackDegrees: 90, groundSpeedKt: nil, observer: observer) == nil)
        #expect(Geodesy.closestPointOfApproach(target: target, trackDegrees: 90, groundSpeedKt: 0, observer: observer) == nil)
    }
}

@Suite("Scope geometry")
struct ScopeGeometryTests {
    private let size = CGSize(width: 200, height: 200)

    @Test("North-up places a due-north target at the top")
    func northUp() {
        let geometry = ScopeGeometry(size: size, rangeNM: 20, rotation: 0, inset: 0)
        let point = geometry.point(bearingDegrees: 0, distanceNM: 20)

        #expect(abs(point.x - 100) < 0.01)
        #expect(abs(point.y - 0) < 0.01)
    }

    @Test("Heading-up rotates the scope under the target")
    func headingUp() {
        let geometry = ScopeGeometry(size: size, rangeNM: 20, rotation: 90, inset: 0)
        // Facing east, a target due east is straight ahead — at the top of the scope.
        let point = geometry.point(bearingDegrees: 90, distanceNM: 20)

        #expect(abs(point.x - 100) < 0.01)
        #expect(abs(point.y - 0) < 0.01)
    }

    @Test("Distance scales linearly to the ring radius")
    func linearScale() {
        let geometry = ScopeGeometry(size: size, rangeNM: 20, rotation: 0, inset: 0)

        let half = geometry.point(bearingDegrees: 90, distanceNM: 10)
        #expect(abs(half.x - 150) < 0.01)

        let centre = geometry.point(bearingDegrees: 90, distanceNM: 0)
        #expect(abs(centre.x - 100) < 0.01)
    }

    @Test("A target beyond the range is pinned to the edge, not dropped")
    func clampedToEdge() {
        let geometry = ScopeGeometry(size: size, rangeNM: 20, rotation: 0, inset: 0)
        let point = geometry.point(bearingDegrees: 90, distanceNM: 400)

        #expect(abs(point.x - 200) < 0.01)
        #expect(geometry.isInRange(distanceNM: 400) == false)
    }
}
