import Foundation
import Testing

@Suite("Response decoding")
struct DecodingTests {
    /// Fixed reference time so position ages are deterministic rather than clock-dependent.
    private static let now = Fixtures.fullResponseTimestamp

    @Test("A full response decodes every field group")
    func fullResponse() throws {
        let response = try Fixtures.decodeResponse(Fixtures.fullResponse)

        #expect(response.aircraft.count == 1)
        #expect(response.nextPageLink == nil)
        #expect(response.malformedMemberErrors.isEmpty)

        let aircraft = try #require(response.aircraft.first)
        #expect(aircraft.faFlightID == "UAL328-1675633671-airline-0123")
        #expect(aircraft.id == "UAL328-1675633671-airline-0123")
        #expect(aircraft.ident == "UAL328")
        #expect(aircraft.callsign == "UAL328")
        #expect(aircraft.identICAO == "UAL328")
        #expect(aircraft.identIATA == "UA328")
        #expect(aircraft.typeCode == "B739")
        // Altitude arrives in hundreds of feet.
        #expect(aircraft.altBaro == .feet(12000))
        #expect(aircraft.groundSpeed == 312)
        #expect(aircraft.track == 210)
        #expect(aircraft.verticalTrend == .descending)
        #expect(aircraft.routeSummary == "SFO → DEN")
        #expect(aircraft.origin?.name == "San Francisco Intl")
    }

    @Test("Altitude zero reads as on the ground")
    func groundAltitude() throws {
        let response = try Fixtures.decodeResponse(Fixtures.groundResponse)
        let aircraft = try #require(response.aircraft.first)

        #expect(aircraft.altBaro == .onGround)
        #expect(aircraft.altBaro?.isOnGround == true)
        #expect(aircraft.altBaro?.feetValue == nil)
    }

    @Test("Altitude is read as hundreds of feet", arguments: [(1, 100), (120, 12_000), (410, 41_000)])
    func altitudeScaling(testCase: (raw: Int, feet: Int)) {
        #expect(BarometricAltitude(hundredsOfFeet: testCase.raw) == .feet(testCase.feet))
    }

    @Test("A malformed member fails that flight, not the response")
    func malformedMember() throws {
        let response = try Fixtures.decodeResponse(Fixtures.malformedMemberResponse)

        #expect(response.aircraft.count == 2)
        #expect(response.aircraft.map(\.faFlightID) == ["aaa111", "ccc333"])
        #expect(response.malformedMemberErrors.count == 1)
    }

    @Test("An empty sky is a normal response, not a failure")
    func emptySky() throws {
        let response = try Fixtures.decodeResponse(Fixtures.emptyResponse)
        #expect(response.aircraft.isEmpty)
        #expect(response.malformedMemberErrors.isEmpty)
    }

    @Test("A missing `flights` array is an empty sky, not a failure")
    func missingFlightsArray() throws {
        let response = try Fixtures.decodeResponse(#"{"num_pages": 1}"#)
        #expect(response.aircraft.isEmpty)
    }

    @Test("A next-page link is surfaced so truncation can be logged")
    func pagedResponse() throws {
        let response = try Fixtures.decodeResponse(Fixtures.pagedResponse)
        #expect(response.nextPageLink == "/flights/search?query=x&cursor=abc123")
    }

    @Test("An empty object decodes — every field really is optional")
    func emptyAircraft() throws {
        let aircraft = try Fixtures.decodeAircraft("{}")

        #expect(aircraft.faFlightID == nil)
        #expect(aircraft.callsign == nil)
        #expect(aircraft.resolvedPosition() == nil)
        #expect(aircraft.displayName == "Unknown")
        #expect(aircraft.altBaro == nil)
        #expect(aircraft.verticalTrend == .level)
    }

    @Test("A flight with no last_position cannot be placed")
    func positionless() throws {
        let response = try Fixtures.decodeResponse(Fixtures.positionlessResponse)
        let aircraft = try #require(response.aircraft.first)
        #expect(aircraft.resolvedPosition() == nil)
    }

    @Test("MLAT positions are marked as such")
    func mlatSource() throws {
        let response = try Fixtures.decodeResponse(Fixtures.mlatResponse)
        let aircraft = try #require(response.aircraft.first)
        let position = try #require(aircraft.resolvedPosition(now: Self.now))

        #expect(position.source == .mlat)
        #expect(position.needsCaution)
        #expect(aircraft.sourceLabel == "MLAT")
    }

    @Test("Projected positions are never presented as fixes")
    func projectedSource() throws {
        let response = try Fixtures.decodeResponse(Fixtures.projectedResponse)
        let aircraft = try #require(response.aircraft.first)
        let position = try #require(aircraft.resolvedPosition(now: Self.now))

        #expect(position.source == .estimated)
        #expect(position.source.isPrecise == false)
        #expect(position.needsCaution)
        #expect(aircraft.sourceLabel == "Projected")
    }

    @Test(
        "update_type maps to a position source",
        arguments: [
            ("A", PositionSource.reported), ("Z", .reported), ("D", .reported),
            ("O", .reported), ("S", .reported), ("X", .reported),
            ("M", .mlat), ("P", .estimated)
        ]
    )
    func updateTypeMapping(testCase: (raw: String, source: PositionSource)) {
        #expect(PositionSource(updateType: testCase.raw) == testCase.source)
    }

    @Test("An unknown update_type degrades to a reported position")
    func unknownUpdateType() {
        #expect(PositionSource(updateType: "Q") == .reported)
        #expect(PositionSource(updateType: nil) == .reported)
    }

    @Test("Position age is measured from the timestamp")
    func positionAge() throws {
        let response = try Fixtures.decodeResponse(Fixtures.fullResponse)
        let aircraft = try #require(response.aircraft.first)

        let fresh = try #require(aircraft.resolvedPosition(now: Self.now.addingTimeInterval(30)))
        #expect(fresh.ageSeconds == 30)
        #expect(fresh.isStale == false)

        let stale = try #require(aircraft.resolvedPosition(now: Self.now.addingTimeInterval(60)))
        #expect(stale.ageSeconds == 60)
        #expect(stale.isStale)
    }

    @Test("A timestamp in the future reads as zero age rather than negative")
    func clockSkew() throws {
        let response = try Fixtures.decodeResponse(Fixtures.fullResponse)
        let aircraft = try #require(response.aircraft.first)
        let position = try #require(aircraft.resolvedPosition(now: Self.now.addingTimeInterval(-5)))

        #expect(position.ageSeconds == 0)
        #expect(position.isStale == false)
    }

    @Test("An out-of-range coordinate is rejected rather than drawn")
    func invalidCoordinate() throws {
        let aircraft = try Fixtures.decodeAircraft("""
        {"fa_flight_id":"a1","last_position":{"latitude":91.0,"longitude":-122.0,
         "timestamp":"2023-02-05T21:47:51Z","update_type":"A"}}
        """)
        #expect(aircraft.resolvedPosition() == nil)
    }

    @Test("ident_prefix is spelled out", arguments: [
        ("L", "Lifeguard"), ("G", "Medevac"), ("GG", "Medevac"),
        ("A", "Air taxi"), ("H", "Heavy"), ("M", "Medium")
    ])
    func identPrefixLabels(testCase: (raw: String, label: String)) throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"fa_flight_id":"a1","ident_prefix":"\#(testCase.raw)"}"#)
        #expect(aircraft.identPrefixLabel == testCase.label)
    }

    @Test("An unknown ident_prefix has no label rather than a wrong one")
    func unknownIdentPrefix() throws {
        let aircraft = try Fixtures.decodeAircraft(#"{"fa_flight_id":"a1","ident_prefix":"Q"}"#)
        #expect(aircraft.identPrefixLabel == nil)
    }

    @Test("A lifeguard flight carries its prefix through the response")
    func lifeguardFlight() throws {
        let response = try Fixtures.decodeResponse(Fixtures.lifeguardResponse)
        let aircraft = try #require(response.aircraft.first)

        #expect(aircraft.identPrefixLabel == "Lifeguard")
        #expect(aircraft.verticalTrend == .climbing)
    }

    @Test("A route needs both ends to be known")
    func partialRoute() throws {
        let aircraft = try Fixtures.decodeAircraft("""
        {"fa_flight_id":"a1","origin":{"code_iata":"SFO"}}
        """)
        #expect(aircraft.routeSummary == nil)
    }
}

@Suite("Bounding box")
struct BoundingBoxTests {
    @Test("A radius becomes a box that contains it")
    func spansTheRadius() {
        let centre = Coordinate(latitude: 37.3349, longitude: -122.0090)
        let box = BoundingBox(centre: centre, radiusNM: 60)

        // 60 nm is one degree of latitude.
        #expect(abs(box.maxLatitude - (centre.latitude + 1)) < 0.0001)
        #expect(abs(box.minLatitude - (centre.latitude - 1)) < 0.0001)

        // Longitude is wider than latitude away from the equator.
        #expect(box.maxLongitude - centre.longitude > 1)
    }

    @Test("The box is clamped to valid coordinates near the poles")
    func polarClamping() {
        let box = BoundingBox(centre: Coordinate(latitude: 89.5, longitude: 0), radiusNM: 250)

        #expect(box.maxLatitude <= 90)
        #expect(box.minLongitude >= -180)
        #expect(box.maxLongitude <= 180)
    }

    @Test("The query value is four space-separated corners")
    func queryFormatting() {
        let box = BoundingBox(centre: Coordinate(latitude: 0, longitude: 0), radiusNM: 60)
        let parts = box.queryValue.split(separator: " ")

        #expect(parts.count == 4)
        #expect(parts.allSatisfy { Double($0) != nil })
    }
}
