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
        state.markFired(.fifteenMinutes)
        state.markFired(.fifteenMinutes)
        #expect(state.hasFired15)
        // still fires the other milestones
        #expect(state.update(etaMinutes: 28, isLanded: false) == .thirtyMinutes)
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
}
