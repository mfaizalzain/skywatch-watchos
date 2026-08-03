import Foundation

/// Golden responses, held as string literals rather than resource files so the test bundle needs no
/// resource copy phase and the fixtures stay readable next to the assertions that use them.
enum Fixtures {
    static func decodeResponse(_ json: String) throws -> AircraftResponse {
        try JSONDecoder().decode(AircraftResponse.self, from: Data(json.utf8))
    }

    static func decodeAircraft(_ json: String) throws -> Aircraft {
        try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
    }

    /// A complete, well-formed response with one airborne target.
    static let fullResponse = """
    {
      "ac": [
        {
          "hex": "a1b2c3",
          "type": "adsb_icao",
          "flight": "UAL328  ",
          "r": "N77258",
          "t": "B739",
          "dbFlags": 0,
          "alt_baro": 12000,
          "alt_geom": 12350,
          "gs": 312.4,
          "ias": 280,
          "tas": 330,
          "mach": 0.52,
          "track": 210.3,
          "baro_rate": -1216,
          "geom_rate": -1184,
          "true_heading": 208.1,
          "mag_heading": 194.8,
          "roll": -1.4,
          "squawk": "3651",
          "emergency": "none",
          "category": "A3",
          "nav_qnh": 1013.6,
          "nav_altitude_mcp": 10000,
          "nav_modes": ["autopilot", "vnav", "lnav"],
          "lat": 37.402100,
          "lon": -122.055300,
          "nic": 8,
          "rc": 186,
          "seen_pos": 0.9,
          "version": 2,
          "nac_p": 9,
          "nac_v": 2,
          "sil": 3,
          "sil_type": "perhour",
          "gva": 2,
          "sda": 2,
          "alert": 0,
          "spi": 0,
          "wd": 270,
          "ws": 42,
          "oat": -18,
          "tat": -4,
          "messages": 41283,
          "seen": 0.4,
          "rssi": -14.2
        }
      ],
      "msg": "No error",
      "now": 1675633671226,
      "total": 1,
      "ctime": 1675633671226,
      "ptime": 3
    }
    """

    /// `alt_baro` as the string "ground".
    static let groundResponse = """
    {
      "ac": [
        {"hex": "d00d00", "flight": "ASA119  ", "alt_baro": "ground", "gs": 12,
         "lat": 37.3626, "lon": -121.9290, "seen_pos": 0.5, "type": "adsb_icao"}
      ],
      "msg": "No error", "now": 1675633671226, "total": 1
    }
    """

    /// The API reporting a problem in `msg`.
    static let errorMessageResponse = """
    {"ac": [], "msg": "Rate limit exceeded", "now": 1675633671226, "total": 0}
    """

    /// No top-level position; only `lastPosition`.
    static let lastPositionResponse = """
    {
      "ac": [
        {"hex": "abc123", "flight": "SKW5541 ", "alt_baro": 8000, "seen": 74.2, "type": "adsb_icao",
         "lastPosition": {"lat": 37.1500, "lon": -121.8000, "nic": 8, "rc": 186, "seen_pos": 74.2}}
      ],
      "msg": "No error", "now": 1675633671226, "total": 1
    }
    """

    /// Heard on Mode S with only a receiver-estimated position.
    static let receiverEstimatedResponse = """
    {
      "ac": [
        {"hex": "beef01", "t": "GLF6", "type": "mode_s", "seen": 41.0,
         "rr_lat": 37.44, "rr_lon": -122.15}
      ],
      "msg": "No error", "now": 1675633671226, "total": 1
    }
    """

    /// A non-ICAO address, prefixed with `~`.
    static let tildeHexResponse = """
    {
      "ac": [
        {"hex": "~abc999", "flight": "N512TS  ", "alt_baro": 3100, "lat": 37.26, "lon": -122.14,
         "seen_pos": 2.0, "type": "tisb_icao"}
      ],
      "msg": "No error", "now": 1675633671226, "total": 1
    }
    """

    /// One malformed member (`alt_baro` is a nonsense string) between two valid ones.
    static let malformedMemberResponse = """
    {
      "ac": [
        {"hex": "aaa111", "flight": "AAL1     ", "alt_baro": 30000, "lat": 37.4, "lon": -122.0, "seen_pos": 1.0},
        {"hex": "bbb222", "flight": "BAW2    ", "alt_baro": "somewhere", "lat": 37.5, "lon": -122.1},
        {"hex": "ccc333", "flight": "DAL3    ", "alt_baro": 27000, "lat": 37.6, "lon": -122.2, "seen_pos": 1.0}
      ],
      "msg": "No error", "now": 1675633671226, "total": 3
    }
    """

    /// `now` in seconds rather than milliseconds — the documented form.
    static let secondsTimestampResponse = """
    {"ac": [], "msg": "No error", "now": 1675633671, "total": 0}
    """
}
