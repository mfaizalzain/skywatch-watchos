import Foundation

/// Golden responses, held as string literals rather than resource files so the test bundle needs no
/// resource copy phase and the fixtures stay readable next to the assertions that use them.
///
/// Shaped after AeroAPI's `/flights/search` payload.
enum Fixtures {
    /// Matches the decoder the client uses: AeroAPI stamps positions in ISO 8601.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func decodeResponse(_ json: String) throws -> AircraftResponse {
        try decoder.decode(AircraftResponse.self, from: Data(json.utf8))
    }

    static func decodeAircraft(_ json: String) throws -> Aircraft {
        try decoder.decode(Aircraft.self, from: Data(json.utf8))
    }

    /// A complete, well-formed response with one airborne flight.
    static let fullResponse = """
    {
      "flights": [
        {
          "ident": "UAL328",
          "ident_icao": "UAL328",
          "ident_iata": "UA328",
          "ident_prefix": null,
          "fa_flight_id": "UAL328-1675633671-airline-0123",
          "aircraft_type": "B739",
          "origin": {
            "code": "KSFO", "code_icao": "KSFO", "code_iata": "SFO",
            "name": "San Francisco Intl", "city": "San Francisco"
          },
          "destination": {
            "code": "KDEN", "code_icao": "KDEN", "code_iata": "DEN",
            "name": "Denver Intl", "city": "Denver"
          },
          "last_position": {
            "fa_flight_id": "UAL328-1675633671-airline-0123",
            "altitude": 120,
            "altitude_change": "D",
            "groundspeed": 312,
            "heading": 210,
            "latitude": 37.402100,
            "longitude": -122.055300,
            "timestamp": "2023-02-05T21:47:51Z",
            "update_type": "A"
          }
        }
      ],
      "links": null,
      "num_pages": 1
    }
    """

    /// The position timestamp used by `fullResponse`, for age assertions.
    static let fullResponseTimestamp = ISO8601DateFormatter().date(from: "2023-02-05T21:47:51Z")!

    /// Altitude zero — on or near the surface.
    static let groundResponse = """
    {
      "flights": [
        {
          "ident": "ASA119",
          "fa_flight_id": "ASA119-1675633671-airline-0001",
          "last_position": {
            "altitude": 0, "altitude_change": "-", "groundspeed": 12, "heading": 150,
            "latitude": 37.3626, "longitude": -121.9290,
            "timestamp": "2023-02-05T21:47:51Z", "update_type": "X"
          }
        }
      ],
      "num_pages": 1
    }
    """

    /// An empty sky, which is a normal response rather than an error.
    static let emptyResponse = """
    {"flights": [], "links": null, "num_pages": 1}
    """

    /// A multilaterated position — real, but lower confidence.
    static let mlatResponse = """
    {
      "flights": [
        {
          "ident": "N512TS",
          "fa_flight_id": "N512TS-1675633671-adhoc-0002",
          "aircraft_type": "C172",
          "last_position": {
            "altitude": 31, "altitude_change": "-", "groundspeed": 98, "heading": 310,
            "latitude": 37.26, "longitude": -122.14,
            "timestamp": "2023-02-05T21:47:51Z", "update_type": "M"
          }
        }
      ],
      "num_pages": 1
    }
    """

    /// A projected position — extrapolated, never to be presented as a fix.
    static let projectedResponse = """
    {
      "flights": [
        {
          "ident": "N600GX",
          "fa_flight_id": "N600GX-1675633671-adhoc-0003",
          "aircraft_type": "GLF6",
          "last_position": {
            "altitude": 410, "altitude_change": "-", "groundspeed": 480, "heading": 20,
            "latitude": 37.44, "longitude": -122.15,
            "timestamp": "2023-02-05T21:47:51Z", "update_type": "P"
          }
        }
      ],
      "num_pages": 1
    }
    """

    /// A flight with no `last_position` at all — cannot be placed on the scope.
    static let positionlessResponse = """
    {
      "flights": [
        {"ident": "SWA99", "fa_flight_id": "SWA99-1675633671-airline-0004", "last_position": null}
      ],
      "num_pages": 1
    }
    """

    /// A lifeguard flight, via `ident_prefix`.
    static let lifeguardResponse = """
    {
      "flights": [
        {
          "ident": "N911MD",
          "ident_prefix": "L",
          "fa_flight_id": "N911MD-1675633671-adhoc-0005",
          "last_position": {
            "altitude": 42, "altitude_change": "C", "groundspeed": 210, "heading": 95,
            "latitude": 37.38, "longitude": -122.05,
            "timestamp": "2023-02-05T21:47:51Z", "update_type": "A"
          }
        }
      ],
      "num_pages": 1
    }
    """

    /// One malformed member (`altitude` is a string) between two valid ones.
    static let malformedMemberResponse = """
    {
      "flights": [
        {"ident": "AAL1", "fa_flight_id": "aaa111",
         "last_position": {"altitude": 300, "groundspeed": 400, "heading": 90,
          "latitude": 37.4, "longitude": -122.0, "timestamp": "2023-02-05T21:47:51Z", "update_type": "A"}},
        {"ident": "BAW2", "fa_flight_id": "bbb222",
         "last_position": {"altitude": "somewhere", "latitude": 37.5, "longitude": -122.1}},
        {"ident": "DAL3", "fa_flight_id": "ccc333",
         "last_position": {"altitude": 270, "groundspeed": 420, "heading": 100,
          "latitude": 37.6, "longitude": -122.2, "timestamp": "2023-02-05T21:47:51Z", "update_type": "A"}}
      ],
      "num_pages": 1
    }
    """

    /// A paged result set, so the scan can log that it truncated.
    static let pagedResponse = """
    {
      "flights": [],
      "links": {"next": "/flights/search?query=x&cursor=abc123"},
      "num_pages": 2
    }
    """
}
