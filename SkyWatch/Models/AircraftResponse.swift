import Foundation

/// Decodes a `T`, or records why it couldn't, without failing its container.
///
/// One malformed flight object in a 40-result response must not cost us the other 39.
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

/// The root object returned by AeroAPI's `/flights/search`.
struct AircraftResponse: Sendable, Decodable {
    let aircraft: [Aircraft]
    /// Cursor to the next page, when the result set was truncated. The scan asks for one page, so
    /// this is kept only to tell the log that more was available.
    let nextPageLink: String?

    /// Decode failures for individual members, kept for logging rather than display.
    let malformedMemberErrors: [String]

    enum CodingKeys: String, CodingKey {
        case flights, links
    }

    enum LinkKeys: String, CodingKey {
        case next
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // A missing array is an empty sky, which is a normal response rather than an error.
        let members = try container.decodeIfPresent([FailableDecodable<Aircraft>].self, forKey: .flights) ?? []
        aircraft = members.compactMap(\.value)
        malformedMemberErrors = members.compactMap(\.error)

        let links = try? container.nestedContainer(keyedBy: LinkKeys.self, forKey: .links)
        nextPageLink = try links?.decodeIfPresent(String.self, forKey: .next)
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
    /// The AeroAPI key is missing, invalid, or out of allowance.
    case unauthorized
}
