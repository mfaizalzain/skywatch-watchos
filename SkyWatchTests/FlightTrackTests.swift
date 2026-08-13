import Foundation
import Testing

@Suite("Flight tracking")
struct FlightTrackTests {
    // MARK: - Flight number parsing

    @Test("IATA flight number converts to ICAO callsign")
    func parsesIATAAndConvertsToICAO() {
        #expect(FlightNumber.parse("MH123")?.callsign == "MAS123")
    }

    @Test("Already-ICAO input passes through")
    func parsesAlreadyICAO() {
        #expect(FlightNumber.parse("MAS123")?.callsign == "MAS123")
    }

    @Test("Unmapped airline falls back to the typed prefix")
    func parsesUnmappedAirline() {
        // "XX" is not in the mapping — the callsign keeps the typed prefix.
        #expect(FlightNumber.parse("XX42")?.callsign == "XX42")
    }

    @Test("Messy input is normalised")
    func parsesMessyInput() {
        #expect(FlightNumber.parse("mh 123")?.callsign == "MAS123")
        #expect(FlightNumber.parse("MH-123")?.callsign == "MAS123")
        #expect(FlightNumber.parse("sq321")?.callsign == "SIA321")
    }

    @Test("Garbage is rejected")
    func rejectsGarbage() {
        #expect(FlightNumber.parse("123") == nil)
        #expect(FlightNumber.parse("MH") == nil)
        #expect(FlightNumber.parse("MH12345") == nil)
        #expect(FlightNumber.parse("") == nil)
        #expect(FlightNumber.parse("MAS-ABC") == nil)
    }

    // MARK: - ETA math

    @Test("ETA from distance and speed")
    func etaFromDistanceAndSpeed() {
        // 300 NM at 400 kt = 45 min
        let eta = FlightTracker.etaMinutes(distanceNM: 300, groundSpeedKnots: 400)
        #expect(eta != nil)
        #expect(abs(eta! - 45) < 0.01)
    }

    @Test("ETA is nil without speed")
    func etaNilWithoutSpeed() {
        #expect(FlightTracker.etaMinutes(distanceNM: 300, groundSpeedKnots: 0) == nil)
        #expect(FlightTracker.etaMinutes(distanceNM: 300, groundSpeedKnots: .nan) == nil)
    }

    @Test("ETA is nil without distance")
    func etaNilWithoutDistance() {
        #expect(FlightTracker.etaMinutes(distanceNM: .infinity, groundSpeedKnots: 400) == nil)
    }

    // MARK: - Alert state machine

    @Test("30-minute alert fires once when ETA first drops below 30")
    func fires30Once() {
        var state = FlightAlertState()
        #expect(state.update(etaMinutes: 45, isLanded: false) == nil)
        #expect(state.update(etaMinutes: 32, isLanded: false) == nil)
        #expect(state.update(etaMinutes: 28, isLanded: false) == .thirtyMinutes)
        // Doesn't fire again while still below 30
        #expect(state.update(etaMinutes: 20, isLanded: false) == nil)
    }

    @Test("15-minute alert fires after 30")
    func fires15After30() {
        var state = FlightAlertState()
        _ = state.update(etaMinutes: 28, isLanded: false) // 30 fires
        #expect(state.update(etaMinutes: 14, isLanded: false) == .fifteenMinutes)
    }

    @Test("Fast descent fires 15 directly, skipping 30")
    func fires15Directly() {
        var state = FlightAlertState()
        // ETA jumps from 40 straight to 10 — 15 fires (most urgent), 30 never does.
        #expect(state.update(etaMinutes: 40, isLanded: false) == nil)
        #expect(state.update(etaMinutes: 10, isLanded: false) == .fifteenMinutes)
        #expect(!state.hasFired30)
    }

    @Test("15-minute alert suppresses the 30-minute one for the rest of the session")
    func fires15Suppresses30() {
        var state = FlightAlertState()
        // Tracking starts with the flight already inside the 15-minute window:
        // the 15-minute alert fires, and a later "30 minutes to landing" would
        // be nonsense — it must never follow.
        #expect(state.update(etaMinutes: 12, isLanded: false) == .fifteenMinutes)
        #expect(state.update(etaMinutes: 10, isLanded: false) == nil)
        #expect(!state.hasFired30)
    }

    @Test("markFired 15-minute alert suppresses 30")
    func markFired15Suppresses30() {
        var state = FlightAlertState()
        // The 15-minute alert fired from the notification system while the app
        // was suspended; a resumed poll inside the 30-minute window must not
        // replay a now-meaningless 30-minute alert.
        state.markFired(.fifteenMinutes)
        #expect(state.update(etaMinutes: 10, isLanded: false) == nil)
        #expect(!state.hasFired30)
    }

    @Test("Landed fires once")
    func landedFiresOnce() {
        var state = FlightAlertState()
        #expect(state.update(etaMinutes: nil, isLanded: true) == .landed)
        #expect(state.update(etaMinutes: nil, isLanded: true) == nil)
        #expect(state.hasFiredLanded)
    }

    @Test("Landed takes priority over ETA alerts")
    func landedTakesPriority() {
        var state = FlightAlertState()
        #expect(state.update(etaMinutes: 12, isLanded: true) == .landed)
        #expect(!state.hasFired15)
        #expect(!state.hasFired30)
    }

    @Test("Landed suppresses the ETA alerts that come after it")
    func landedSuppressesLaterETAAlerts() {
        var state = FlightAlertState()
        #expect(state.update(etaMinutes: 12, isLanded: true) == .landed)
        // Official landed verdict, then a poll that still reports a finite ETA:
        // no heads-up may follow the landing.
        #expect(state.update(etaMinutes: 20, isLanded: false) == nil)
        #expect(state.update(etaMinutes: 8, isLanded: false) == nil)
        #expect(!state.hasFired15)
        #expect(!state.hasFired30)
    }

    @Test("markFired records an alert that fired from the notification system")
    func markFiredRecordsDeliveredAlert() {
        var state = FlightAlertState()
        state.markFired(.landed)
        #expect(state.hasFiredLanded)
        // update() won't replay it
        #expect(state.update(etaMinutes: nil, isLanded: true) == nil)
    }

    @Test("markFired is idempotent")
    func markFiredIsIdempotent() {
        var state = FlightAlertState()
        state.markFired(.thirtyMinutes)
        state.markFired(.thirtyMinutes)
        #expect(state.hasFired30)
        // still fires the more urgent milestone as the flight gets closer
        #expect(state.update(etaMinutes: 12, isLanded: false) == .fifteenMinutes)
    }

    // MARK: - Live status

    @Test("Flight is live when airborne")
    func isLiveWhenAirborne() {
        #expect(FlightPhase.inAir(etaMinutes: 25).isLive)
        #expect(FlightPhase.inAir(etaMinutes: nil).isLive)
    }

    @Test("Flight is live when on the ground")
    func isLiveWhenOnGround() {
        #expect(FlightPhase.onGround(distanceNM: 3).isLive)
    }

    @Test("Flight is not live when not found or disappeared")
    func notLiveWhenNotFoundOrDisappeared() {
        #expect(!FlightPhase.notFound.isLive)
        #expect(!FlightPhase.disappeared.isLive)
        #expect(!FlightPhase.idle.isLive)
        #expect(!FlightPhase.searching.isLive)
    }

    @Test("Live label matches phase")
    func liveLabelMatchesPhase() {
        #expect(FlightPhase.inAir(etaMinutes: 20).liveLabel == "LIVE — in the air")
        #expect(FlightPhase.notFound.liveLabel == "Not live right now")
        #expect(FlightPhase.disappeared.liveLabel == "Landed (left the feed)")
    }

    // MARK: - Landed-after-disappearance

    @Test("Disappearance near the airport counts as landed")
    func disappearanceNearAirportIsLanded() {
        #expect(FlightTracker.isLandedAfterDisappearance(lastDistanceNM: 10))
        #expect(FlightTracker.isLandedAfterDisappearance(lastDistanceNM: 25))
    }

    @Test("Disappearance far from the airport is not landed")
    func disappearanceFarIsNotLanded() {
        #expect(!FlightTracker.isLandedAfterDisappearance(lastDistanceNM: 500))
        #expect(!FlightTracker.isLandedAfterDisappearance(lastDistanceNM: nil))
    }

    // MARK: - Airports catalog sanity

    @Test("Airport IATA codes are unique")
    func airportCodesAreUnique() {
        let codes = Set(Airport.common.map(\.iata))
        #expect(codes.count == Airport.common.count, "duplicate IATA codes in catalog")
        #expect(Airport.common.count > 50)
    }

    @Test("Airport coordinates are valid")
    func airportCoordinatesAreValid() {
        for airport in Airport.common {
            #expect((-90...90).contains(airport.coordinate.latitude), "\(airport.iata) lat")
            #expect((-180...180).contains(airport.coordinate.longitude), "\(airport.iata) lon")
        }
    }

    // MARK: - Scheduled alert arming (the screen-off path)

    @Test("Landed alert is armed from the live ETA when no official arrival exists")
    func armsLandedFromLiveETA() {
        let state = FlightAlertState()
        let now = Date()
        let plans = state.scheduledAlerts(etaMinutes: 25, officialArrival: nil, now: now)

        // The screen-off backstop: without an AeroAPI key there is no official arrival, so the
        // landing alert is armed for `now + ETA` and fires from the notification system even
        // while the app is suspended.
        let landed = plans.first { $0.alert == .landed }
        #expect(landed != nil)
        #expect(abs(landed!.fireAt.timeIntervalSince(now) - 25 * 60) < 1,
                "landed alert armed for now + ETA")

        // ETA 25 sits inside the 30-minute window: the 30 heads-up is the live path's to fire,
        // so nothing stale is armed behind it; the 15 one arms for 10 minutes out.
        #expect(!plans.contains { $0.alert == .thirtyMinutes })
        #expect(plans.contains { $0.alert == .fifteenMinutes })
    }

    @Test("Landed alert is armed from the official arrival when known")
    func armsLandedFromOfficialArrival() {
        let arrival = Date().addingTimeInterval(3 * 3600)
        let plans = FlightAlertState().scheduledAlerts(etaMinutes: nil, officialArrival: arrival)
        #expect(plans.contains { $0.alert == .landed && $0.fireAt == arrival })
    }

    @Test("Nothing is armed without an ETA or official arrival")
    func armsNothingWithoutTiming() {
        let plans = FlightAlertState().scheduledAlerts(etaMinutes: nil, officialArrival: nil)
        #expect(plans.isEmpty)
    }

    @Test("Fired 15-minute alert suppresses a later 30-minute arming")
    func fired15SuppressesLaterArming() {
        var state = FlightAlertState()
        _ = state.update(etaMinutes: 12, isLanded: false) // 15 fires live

        // ETA drifts back out of the window (the flight slowed): a stale "30 minutes"
        // notification must not be armed behind the 15-minute one, and 15 is not re-armed.
        let plans = state.scheduledAlerts(etaMinutes: 45, officialArrival: nil)
        #expect(!plans.contains { $0.alert == .thirtyMinutes })
        #expect(!plans.contains { $0.alert == .fifteenMinutes })

        // The landing alert is still armed from the live ETA.
        #expect(plans.contains { $0.alert == .landed })
    }

    @Test("Fired landed alert arms nothing further")
    func firedLandedArmsNothing() {
        var state = FlightAlertState()
        state.markFired(.landed)
        #expect(state.scheduledAlerts(etaMinutes: 20, officialArrival: nil).isEmpty)
        #expect(state.scheduledAlerts(etaMinutes: 40, officialArrival: Date()).isEmpty)
    }
}
