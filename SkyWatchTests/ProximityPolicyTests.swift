import Foundation
import Testing

@Suite("Proximity haptic policy")
struct ProximityPolicyTests {
    @Test("Alerts inside the distance and altitude thresholds")
    func alertsInsideThresholds() {
        #expect(ProximityPolicy.shouldAlert(
            distanceNM: 2.9, altitudeFeet: 7_000, isPinned: false,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
    }

    @Test("No alert beyond the distance threshold")
    func noAlertBeyondDistance() {
        #expect(!ProximityPolicy.shouldAlert(
            distanceNM: 3.1, altitudeFeet: 7_000, isPinned: false,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
    }

    @Test("No alert above the altitude threshold")
    func noAlertAboveAltitude() {
        #expect(!ProximityPolicy.shouldAlert(
            distanceNM: 2.0, altitudeFeet: 8_500, isPinned: false,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
    }

    @Test("No alert without an altitude reading")
    func noAlertWithoutAltitude() {
        #expect(!ProximityPolicy.shouldAlert(
            distanceNM: 2.0, altitudeFeet: nil, isPinned: false,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
    }

    @Test("Pinned targets alert from twice the distance")
    func pinnedAlertsFromTwiceTheDistance() {
        // 5.5 nm is outside the 3 nm threshold but inside the pinned 6 nm.
        #expect(ProximityPolicy.shouldAlert(
            distanceNM: 5.5, altitudeFeet: 7_000, isPinned: true,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
        #expect(!ProximityPolicy.shouldAlert(
            distanceNM: 6.1, altitudeFeet: 7_000, isPinned: true,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
    }

    @Test("Thresholds themselves do not alert")
    func thresholdsDoNotAlert() {
        // "Inside" is strict: exactly at the threshold is not yet inside.
        #expect(!ProximityPolicy.shouldAlert(
            distanceNM: 3, altitudeFeet: 7_000, isPinned: false,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
        #expect(!ProximityPolicy.shouldAlert(
            distanceNM: 2, altitudeFeet: 8_000, isPinned: false,
            distanceThresholdNM: 3, altitudeThresholdFeet: 8_000
        ))
    }
}
