import Foundation

/// Decodes a `T`, or records why it couldn't, without failing its container.
///
/// One malformed aircraft object in a 40-target response must not cost us the other 39.
struct FailableDecodable<T: Decodable & Sendable>: Sendable, Decodable {
    let value: T?
    let error: String?

    init(from decoder: any Decoder) throws {
        do {
            value = try T(from: decoder)
            error = nil
        } catch {
            self.value = nil
            self.error = String(describing: error)
        }
    }
}

/// The root object returned by every v2 endpoint.
struct AircraftResponse: Sendable, Decodable {
    let aircraft: [Aircraft]
    let message: String?
    /// Server time, normalised to seconds since epoch.
    let now: Date?
    let total: Int?
    let cacheTime: Date?
    let processingTimeMS: Double?

    /// Decode failures for individual members, kept for logging rather than display.
    let malformedMemberErrors: [String]

    enum CodingKeys: String, CodingKey {
        case aircraft = "ac"
        case message = "msg"
        case now, total, ctime, ptime
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // The documented key is `aircraft`; the wire format actually uses `ac`. Accept either, and
        // treat a missing array as an empty one — an empty sky is a normal response, not an error.
        let members = try container.decodeIfPresent([FailableDecodable<Aircraft>].self, forKey: .aircraft) ?? []
        aircraft = members.compactMap(\.value)
        malformedMemberErrors = members.compactMap(\.error)

        message = try container.decodeIfPresent(String.self, forKey: .message)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        processingTimeMS = try container.decodeIfPresent(Double.self, forKey: .ptime)

        now = Self.date(from: try container.decodeIfPresent(Double.self, forKey: .now))
        cacheTime = Self.date(from: try container.decodeIfPresent(Double.self, forKey: .ctime))
    }

    /// The docs say seconds; the wire says milliseconds. Anything past ~1e11 is milliseconds
    /// (1e11 seconds is the year 5138, and 1e11 milliseconds is 1973).
    static func date(from raw: Double?) -> Date? {
        guard let raw, raw > 0, raw.isFinite else { return nil }
        return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
    }

    /// The API reports success as the string "No error", so silence is not golden here.
    var apiError: String? {
        guard let message, message.caseInsensitiveCompare("No error") != .orderedSame else { return nil }
        return message
    }
}

/// Every failure the app can be in, and nothing else. Each case maps to one on-screen direction.
enum SkyWatchError: Error, Sendable, Hashable {
    case offline
    case rateLimited
    case server(status: Int)
    case decoding(underlying: String)
    case locationDenied
    case locationUnavailable
    case apiMessage(String)
}
