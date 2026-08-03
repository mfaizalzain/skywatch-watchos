import Foundation
import Testing

@Suite("Response decoding")
struct DecodingTests {
    @Test("A full response decodes every field group")
    func fullResponse() throws {
        let response = try Fixtures.decodeResponse(Fixtures.fullResponse)

        #expect(response.aircraft.count == 1)
        #expect(response.apiError == nil)
        #expect(response.total == 1)
        #expect(response.malformedMemberErrors.isEmpty)

        let aircraft = try #require(response.aircraft.first)
        #expect(aircraft.hex == "a1b2c3")
        // The wire pads the callsign to eight characters.
        #expect(aircraft.flight == "UAL328  ")
        #expect(aircraft.callsign == "UAL328")
        #expect(aircraft.registration == "N77258")
        #expect(aircraft.typeCode == "B739")
        #expect(aircraft.altBaro == .feet(12000))
        #expect(aircraft.groundSpeed == 312.4)
        #expect(aircraft.navModeList == ["autopilot", "vnav", "lnav"])
        #expect(aircraft.emergency == .none)
        #expect(aircraft.outsideAirTemperature == -18)
        #expect(aircraft.verticalTrend == .descending)
    }

    @Test("Milliseconds in `now` are normalised to seconds")
    func millisecondTimestamp() throws {
        let response = try Fixtures.decodeResponse(Fixtures.fullResponse)
        let now = try #require(response.now)
        #expect(abs(now.timeIntervalSince1970 - 1_675_633_671.226) < 0.01)
    }

    @Test("Seconds in `now` are left alone")
    func secondTimestamp() throws {
        let response = try Fixtures.decodeResponse(Fixtures.secondsTimestampResponse)
        let now = try #require(response.now)
        #expect(abs(now.timeIntervalSince1970 - 1_675_633_671) < 0.01)
    }

    @Test("`alt_baro` accepts the string \"ground\"")
    func groundAltitude() throws {
        let response = try Fixtures.decodeResponse(Fixtures.groundResponse)
        let aircraft = try #require(response.aircraft.first)

        #expect(aircraft.altBaro == .onGround)
        #expect(aircraft.altBaro?.isOnGround == true)
        #expect(aircraft.altBaro?.feetValue == nil)
    }

    @Test("An unrecognised `alt_baro` string fails that aircraft, not the response")
    func unrecognisedAltitudeString() throws {
        let response = try Fixtures.decodeResponse(Fixtures.malformedMemberResponse)

        #expect(response.aircraft.count == 2)
        #expect(response.aircraft.map(\.hex) == ["aaa111", "ccc333"])
        #expect(response.malformedMemberErrors.count == 1)
    }

    @Test("`msg` other than \"No error\" is surfaced")
    func apiErrorMessage() throws {
        let response = try Fixtures.decodeResponse(Fixtures.errorMessageResponse)
        #expect(response.apiError == "Rate limit exceeded")
    }

    @Test("\"No error\" is not an error")
    func noErrorMessage() throws {
        let response = try Fixtures.decodeResponse(Fixtures.fullResponse)
        #expect(response.apiError == nil)
    }

    @Test("A target with only `lastPosition` resolves stale")
    func lastPositionOnly() throws {
        let response = try Fixtures.decodeResponse(Fixtures.lastPositionResponse)
        let aircraft = try #require(response.aircraft.first)
        let position = try #require(aircraft.resolvedPosition)

        #expect(position.coordinate.latitude == 37.15)
        #expect(position.source == .reported)
        #expect(position.isStale)
        #expect(position.needsCaution)
        #expect(position.ageSeconds == 74.2)
    }

    @Test("A target with only `rr_lat`/`rr_lon` resolves estimated")
    func receiverEstimatedOnly() throws {
        let response = try Fixtures.decodeResponse(Fixtures.receiverEstimatedResponse)
        let aircraft = try #require(response.aircraft.first)
        let position = try #require(aircraft.resolvedPosition)

        #expect(position.source == .estimated)
        #expect(position.source.isPrecise == false)
        #expect(position.needsCaution)
        #expect(aircraft.sourceType == "mode_s")
    }

    @Test("A `~` hex is kept for identity and stripped for display")
    func tildeHex() throws {
        let response = try Fixtures.decodeResponse(Fixtures.tildeHexResponse)
        let aircraft = try #require(response.aircraft.first)

        #expect(aircraft.hex == "~abc999")
        #expect(aircraft.id == "~abc999")
        #expect(aircraft.displayHex == "abc999")
        #expect(aircraft.isNonICAOAddress)
    }

    @Test("An empty object decodes — every field really is optional")
    func emptyAircraft() throws {
        let aircraft = try Fixtures.decodeAircraft("{}")

        #expect(aircraft.hex == nil)
        #expect(aircraft.callsign == nil)
        #expect(aircraft.resolvedPosition == nil)
        #expect(aircraft.isPositionless)
        #expect(aircraft.displayName == "Unknown")
        #expect(aircraft.emergency == .none)
        #expect(aircraft.flags.isEmpty)
    }

    @Test("A missing `ac` array is an empty sky, not a failure")
    func missingAircraftArray() throws {
        let response = try Fixtures.decodeResponse(#"{"msg": "No error", "now": 1675633671226}"#)
        #expect(response.aircraft.isEmpty)
        #expect(response.apiError == nil)
    }

    @Test(
        "dbFlags is read as a bitfield",
        arguments: [
            (0, false, false, false, false),
            (1, true, false, false, false),
            (3, true, true, false, false),
            (8, false, false, false, true),
            (15, true, true, true, true)
        ]
    )
    func databaseFlags(
        testCase: (raw: Int, military: Bool, interesting: Bool, pia: Bool, ladd: Bool)
    ) throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"hex":"a1","dbFlags":\#(testCase.raw)}"#)

        #expect(aircraft.flags.contains(.military) == testCase.military)
        #expect(aircraft.flags.contains(.interesting) == testCase.interesting)
        #expect(aircraft.flags.contains(.pia) == testCase.pia)
        #expect(aircraft.flags.contains(.ladd) == testCase.ladd)
        #expect(aircraft.isMilitary == testCase.military)
    }

    @Test("Emergency squawks are recognised", arguments: ["7500", "7600", "7700"])
    func emergencySquawks(squawk: String) throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"hex":"a1","squawk":"\#(squawk)"}"#)
        #expect(aircraft.hasEmergencySquawk)
        #expect(aircraft.isAlerting)
    }

    @Test("An ordinary squawk is not an emergency")
    func ordinarySquawk() throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"hex":"a1","squawk":"3651"}"#)
        #expect(aircraft.hasEmergencySquawk == false)
        #expect(aircraft.isAlerting == false)
    }

    @Test("An unknown `emergency` value degrades to none rather than failing the decode")
    func unknownEmergencyValue() throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"hex":"a1","emergency":"martian"}"#)
        #expect(aircraft.emergency == .none)
    }

    @Test("A live position wins over lastPosition")
    func livePositionPreferred() throws {
        let aircraft = try Fixtures.decodeAircraft("""
        {"hex":"a1","lat":37.0,"lon":-122.0,"seen_pos":2.0,
         "lastPosition":{"lat":36.0,"lon":-121.0,"seen_pos":90.0}}
        """)
        let position = try #require(aircraft.resolvedPosition)

        #expect(position.coordinate.latitude == 37.0)
        #expect(position.isStale == false)
    }

    @Test("A position older than 60 s is stale")
    func stalenessThreshold() throws {
        let fresh = try Fixtures.decodeAircraft(#"{"hex":"a1","lat":37.0,"lon":-122.0,"seen_pos":59.9}"#)
        let stale = try Fixtures.decodeAircraft(#"{"hex":"a1","lat":37.0,"lon":-122.0,"seen_pos":60.0}"#)

        #expect(fresh.resolvedPosition?.isStale == false)
        #expect(stale.resolvedPosition?.isStale == true)
    }

    @Test("An out-of-range coordinate is rejected rather than drawn")
    func invalidCoordinate() throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"hex":"a1","lat":91.0,"lon":-122.0}"#)
        #expect(aircraft.resolvedPosition == nil)
    }

    @Test("MLAT targets are marked as such")
    func mlatSource() throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"hex":"a1","type":"mlat","lat":37.0,"lon":-122.0,"seen_pos":3.0}"#)
        let position = try #require(aircraft.resolvedPosition)

        #expect(position.source == .mlat)
        #expect(position.needsCaution)
    }
}
