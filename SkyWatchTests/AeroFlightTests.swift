import Foundation
import Testing

@Suite("AeroAPI decoding")
struct AeroFlightDecodingTests {
    /// Trimmed real response for `flights/MH123` (2026-08-04): one upcoming
    /// occurrence, one arrived yesterday.
    private let fixture = """
    {
      "flights": [
        {
          "ident": "MAS123",
          "ident_icao": "MAS123",
          "ident_iata": "MH123",
          "fa_flight_id": "MAS123-1785828730-airline-977p",
          "operator": "MAS",
          "operator_icao": "MAS",
          "operator_iata": "MH",
          "flight_number": "123",
          "status": "Scheduled",
          "aircraft_type": "A339",
          "progress_percent": 0,
          "origin": {"code": "WMKK", "code_icao": "WMKK", "code_iata": "KUL",
                     "city": "Sepang", "name": "Kuala Lumpur Intl", "timezone": "Asia/Kuala_Lumpur"},
          "destination": {"code": "YSSY", "code_icao": "YSSY", "code_iata": "SYD",
                          "city": "Sydney", "name": "Sydney Intl", "timezone": "Australia/Sydney"},
          "scheduled_out": "2026-08-06T22:15:00Z",
          "scheduled_off": "2026-08-06T22:35:00Z",
          "scheduled_on": "2026-08-06T23:51:00Z",
          "scheduled_in": "2026-08-07T00:01:00Z"
        },
        {
          "ident": "MAS123",
          "fa_flight_id": "MAS123-1785566074-airline-1688p",
          "operator": "MAS",
          "flight_number": "123",
          "status": "Arrived / Gate Arrival",
          "aircraft_type": "A339",
          "progress_percent": 100,
          "origin": {"code": "WMKK"},
          "destination": {"code": "YSSY", "gate": "B20", "terminal": "1"},
          "scheduled_out": "2026-08-03T21:00:00Z",
          "actual_on": "2026-08-03T23:41:00Z",
          "actual_in": "2026-08-03T23:48:00Z"
        }
      ]
    }
    """

    private func decode(_ json: String) throws -> AeroFlightResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised date: \(string)")
        }
        return try decoder.decode(AeroFlightResponse.self, from: Data(json.utf8))
    }

    @Test("Decodes a real response")
    func decodesFixture() throws {
        let response = try decode(fixture)
        #expect(response.flights.count == 2)
        let upcoming = response.flights[0]
        #expect(upcoming.ident == "MAS123")
        #expect(upcoming.phase == .scheduled)
        #expect(upcoming.destination?.code == "YSSY")
    }

    @Test("Gate arrival prefers actual over estimated over scheduled")
    func gateArrivalPrecedence() throws {
        let response = try decode(fixture)
        let arrived = response.flights[1]
        let expected = ISO8601DateFormatter().date(from: "2026-08-03T23:48:00Z")
        #expect(arrived.gateArrival == expected)
        #expect(response.flights[0].gateArrival != nil)
    }

    @Test("Status parsing handles AeroAPI's summary strings")
    func statusParsing() {
        #expect(AeroStatus.parse("Scheduled") == .scheduled)
        #expect(AeroStatus.parse("Departed") == .departed)
        #expect(AeroStatus.parse("En Route") == .enRoute)
        #expect(AeroStatus.parse("Landed") == .landed)
        #expect(AeroStatus.parse("Arrived / Gate Arrival") == .arrived)
        #expect(AeroStatus.parse("Cancelled") == .cancelled)
        #expect(AeroStatus.parse("Diverted") == .diverted)
        #expect(AeroStatus.parse("Something Weird") == .unknown)
    }

    @Test("Landed detection")
    func landedDetection() {
        #expect(AeroStatus.landed.hasLanded)
        #expect(AeroStatus.arrived.hasLanded)
        #expect(!AeroStatus.enRoute.hasLanded)
        #expect(!AeroStatus.scheduled.hasLanded)
    }

    @Test("Empty response picks nothing")
    func emptyResponse() {
        let response = AeroFlightResponse(flights: [])
        #expect(AeroFlightPicker.pick(from: response) == nil)
    }
}

@Suite("AeroAPI flight picker")
struct AeroFlightPickerTests {
    private func makeFlight(
        status: String,
        scheduledOut: String,
        actualIn: String? = nil
    ) -> AeroFlight {
        let date: (String) -> Date? = { ISO8601DateFormatter().date(from: $0) }
        return AeroFlight(
            ident: "MAS123",
            faFlightID: "id",
            status: status,
            operatorICAO: "MAS",
            aircraftType: "A339",
            scheduledOut: date(scheduledOut),
            scheduledOff: nil,
            scheduledOn: nil,
            estimatedOn: nil,
            actualOn: nil,
            scheduledIn: nil,
            estimatedIn: nil,
            actualIn: actualIn.flatMap(date),
            progressPercent: nil,
            origin: nil,
            destination: nil
        )
    }

    @Test("Picks the current flight over an arrived one")
    func picksCurrentOverArrived() {
        let now = ISO8601DateFormatter().date(from: "2026-08-04T12:00:00Z")!
        let response = AeroFlightResponse(flights: [
            makeFlight(status: "Arrived / Gate Arrival", scheduledOut: "2026-08-03T21:00:00Z"),
            makeFlight(status: "En Route", scheduledOut: "2026-08-04T10:00:00Z")
        ])
        let picked = AeroFlightPicker.pick(from: response, now: now)
        #expect(picked?.phase == .enRoute)
    }

    @Test("Picks tonight's scheduled flight over tomorrow's")
    func picksNearestScheduled() {
        let now = ISO8601DateFormatter().date(from: "2026-08-04T12:00:00Z")!
        let response = AeroFlightResponse(flights: [
            // API orders by scheduled_out descending: furthest future first.
            makeFlight(status: "Scheduled", scheduledOut: "2026-08-06T22:15:00Z"),
            makeFlight(status: "Scheduled", scheduledOut: "2026-08-04T22:15:00Z")
        ])
        let picked = AeroFlightPicker.pick(from: response, now: now)
        #expect(picked?.phase == .scheduled)
        #expect(picked?.departure == ISO8601DateFormatter().date(from: "2026-08-04T22:15:00Z"))
    }

    @Test("A flight that landed this morning is still tracked (pickup alert)")
    func tracksMorningArrival() {
        let now = ISO8601DateFormatter().date(from: "2026-08-04T12:00:00Z")!
        let response = AeroFlightResponse(flights: [
            makeFlight(status: "Arrived / Gate Arrival", scheduledOut: "2026-08-04T06:00:00Z"),
            makeFlight(status: "Scheduled", scheduledOut: "2026-08-05T22:15:00Z")
        ])
        let picked = AeroFlightPicker.pick(from: response, now: now)
        #expect(picked?.phase == .arrived)
        #expect(picked?.gateArrival != nil)
    }
}
