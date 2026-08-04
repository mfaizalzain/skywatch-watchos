import XCTest
@testable import SkyWatchTests

final class FlightTrackTests: XCTestCase {
    // MARK: - Flight number parsing

    func testParsesIATAAndConvertsToICAOCallsign() {
        let flight = FlightNumber.parse("MH123")
        XCTAssertEqual(flight?.callsign, "MAS123")
    }

    func testParsesAlreadyICAO() {
        let flight = FlightNumber.parse("MAS123")
        XCTAssertEqual(flight?.callsign, "MAS123")
    }

    func testParsesUnmappedAirlineFallsBackToRawPrefix() {
        // "XX" is not in the mapping — the callsign keeps the typed prefix.
        let flight = FlightNumber.parse("XX42")
        XCTAssertEqual(flight?.callsign, "XX42")
    }

    func testParsesMessyInput() {
        XCTAssertEqual(FlightNumber.parse("mh 123")?.callsign, "MAS123")
        XCTAssertEqual(FlightNumber.parse("MH-123")?.callsign, "MAS123")
        XCTAssertEqual(FlightNumber.parse("sq321")?.callsign, "SIA321")
    }

    func testRejectsGarbage() {
        XCTAssertNil(FlightNumber.parse("123"))
        XCTAssertNil(FlightNumber.parse("MH"))
        XCTAssertNil(FlightNumber.parse("MH12345"))
        XCTAssertNil(FlightNumber.parse(""))
        XCTAssertNil(FlightNumber.parse("MAS-ABC"))
    }

    // MARK: - ETA math

    func testETAFromDistanceAndSpeed() {
        // 300 NM at 400 kt = 45 min
        XCTAssertEqual(FlightTracker.etaMinutes(distanceNM: 300, groundSpeedKnots: 400), 45, accuracy: 0.01)
    }

    func testETANilWithoutSpeed() {
        XCTAssertNil(FlightTracker.etaMinutes(distanceNM: 300, groundSpeedKnots: 0))
        XCTAssertNil(FlightTracker.etaMinutes(distanceNM: 300, groundSpeedKnots: .nan))
    }

    func testETANilWithoutDistance() {
        XCTAssertNil(FlightTracker.etaMinutes(distanceNM: .infinity, groundSpeedKnots: 400))
    }

    // MARK: - Alert state machine

    func testFires30WhenETAFirstDropsBelow30() {
        var state = FlightAlertState()
        XCTAssertNil(state.update(etaMinutes: 45, isLanded: false))
        XCTAssertNil(state.update(etaMinutes: 32, isLanded: false))
        XCTAssertEqual(state.update(etaMinutes: 28, isLanded: false), .thirtyMinutes)
        // Doesn't fire again while still below 30
        XCTAssertNil(state.update(etaMinutes: 20, isLanded: false))
    }

    func testFires15After30() {
        var state = FlightAlertState()
        _ = state.update(etaMinutes: 28, isLanded: false) // 30 fires
        XCTAssertEqual(state.update(etaMinutes: 14, isLanded: false), .fifteenMinutes)
    }

    func testFires15DirectlyWithout30ForFastDescent() {
        var state = FlightAlertState()
        // ETA jumps from 40 straight to 10 — 15 fires (most urgent), 30 never does.
        XCTAssertNil(state.update(etaMinutes: 40, isLanded: false))
        XCTAssertEqual(state.update(etaMinutes: 10, isLanded: false), .fifteenMinutes)
        XCTAssertFalse(state.hasFired30)
    }

    func testLandedFiresOnce() {
        var state = FlightAlertState()
        XCTAssertEqual(state.update(etaMinutes: nil, isLanded: true), .landed)
        XCTAssertNil(state.update(etaMinutes: nil, isLanded: true))
        XCTAssertTrue(state.hasFiredLanded)
    }

    func testLandedTakesPriorityOverETAAlerts() {
        var state = FlightAlertState()
        XCTAssertEqual(state.update(etaMinutes: 12, isLanded: true), .landed)
        XCTAssertFalse(state.hasFired15)
        XCTAssertFalse(state.hasFired30)
    }

    // MARK: - Live status

    func testIsLiveWhenAirborne() {
        XCTAssertTrue(FlightPhase.inAir(etaMinutes: 25).isLive)
        XCTAssertTrue(FlightPhase.inAir(etaMinutes: nil).isLive)
    }

    func testIsLiveWhenOnGround() {
        XCTAssertTrue(FlightPhase.onGround(distanceNM: 3).isLive)
    }

    func testNotLiveWhenNotFoundOrDisappeared() {
        XCTAssertFalse(FlightPhase.notFound.isLive)
        XCTAssertFalse(FlightPhase.disappeared.isLive)
        XCTAssertFalse(FlightPhase.idle.isLive)
        XCTAssertFalse(FlightPhase.searching.isLive)
    }

    func testLiveLabelMatchesPhase() {
        XCTAssertEqual(FlightPhase.inAir(etaMinutes: 20).liveLabel, "LIVE — in the air")
        XCTAssertEqual(FlightPhase.notFound.liveLabel, "Not live right now")
        XCTAssertEqual(FlightPhase.disappeared.liveLabel, "Landed (left the feed)")
    }

    // MARK: - Landed-after-disappearance

    func testDisappearanceNearAirportIsLanded() {
        XCTAssertTrue(FlightTracker.isLandedAfterDisappearance(lastDistanceNM: 10))
        XCTAssertTrue(FlightTracker.isLandedAfterDisappearance(lastDistanceNM: 25))
    }

    func testDisappearanceFarFromAirportIsNotLanded() {
        XCTAssertFalse(FlightTracker.isLandedAfterDisappearance(lastDistanceNM: 500))
        XCTAssertFalse(FlightTracker.isLandedAfterDisappearance(lastDistanceNM: nil))
    }

    // MARK: - Airports catalog sanity

    func testAirportCodesAreUnique() {
        let codes = Set(Airport.common.map(\.iata))
        XCTAssertEqual(codes.count, Airport.common.count, "duplicate IATA codes in catalog")
        XCTAssertGreaterThan(Airport.common.count, 50)
    }

    func testAirportCoordinatesAreValid() {
        for airport in Airport.common {
            XCTAssertTrue((-90...90).contains(airport.coordinate.latitude), "\(airport.iata) lat")
            XCTAssertTrue((-180...180).contains(airport.coordinate.longitude), "\(airport.iata) lon")
        }
    }
}
