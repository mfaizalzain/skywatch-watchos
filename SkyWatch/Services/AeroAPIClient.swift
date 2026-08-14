import Foundation
import os

/// FlightAware AeroAPI client — the only thing in this app that touches the
/// network, and the only host it ever talks to.
///
/// AeroAPI is metered: the Personal tier bills per query against a free monthly
/// allowance. Every request in the app goes through this one actor's rate
/// limiter, so the scan loop and the Track tab can never combine to exceed the
/// spacing set below.
///
/// The API key is injected at build time from the `AEROAPI_KEY` build setting
/// (release workflow reads the sealed GitHub secret). It is never in the repo —
/// anyone building this brings their own.
actor AeroAPIClient {
    static let baseURL = URL(string: "https://aeroapi.flightaware.com/aeroapi/")!

    private let apiKey: String
    private let session: URLSession
    private let limiter: RateLimiter
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.fmz.skywatch", category: "aeroapi")

    /// Personal tier allows 10 result sets per minute; stay comfortably under
    /// with one request per 7 s. The scan loop and the Track tab share this
    /// limiter, so their requests queue rather than contend.
    private static let spacing: Duration = .seconds(7)
    private let retryDelays: [Duration] = [.seconds(3), .seconds(8)]
    private let rateLimitBackoff: Duration = .seconds(30)

    /// Whether a key is available in this build (release builds get it from
    /// the workflow secret; local Debug builds have none and skip the layer).
    static var hasConfiguredKey: Bool {
        !(Bundle.main.object(forInfoDictionaryKey: "AeroAPIKey") as? String ?? "").isEmpty
    }

    /// Reads the key from the build-injected Info.plist entry.
    static func configuredKey() -> String {
        Bundle.main.object(forInfoDictionaryKey: "AeroAPIKey") as? String ?? ""
    }

    init(
        apiKey: String = AeroAPIClient.configuredKey(),
        limiter: RateLimiter = RateLimiter(minimumInterval: AeroAPIClient.spacing),
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.limiter = limiter
        self.session = session ?? Self.makeSession()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // AeroAPI emits ISO8601 with and without fractional seconds;
            // ISO8601DateFormatter handles both if given the options.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date: \(string)"
            )
        }
        self.decoder = decoder
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "SkyWatch/1.0 (personal watchOS client)"
        ]
        return URLSession(configuration: configuration)
    }

    /// The scan query: every airborne flight whose last reported position falls inside a box drawn
    /// around the observer.
    ///
    /// AeroAPI has no radius search, so the radius becomes a bounding box and the corners are
    /// trimmed back to a circle by `ScanStore`'s own distance filter.
    func aircraft(near coordinate: Coordinate, radiusNM: Double) async throws -> AircraftResponse {
        let box = BoundingBox(centre: coordinate, radiusNM: radiusNM)
        // max_pages=1 caps the billable result sets: the nearest page is the one that matters, and
        // the tracked-target cap discards the rest anyway.
        let query = "-latlong \"\(box.queryValue)\""
        guard let escapedQuery = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw AeroAPIError.badRequest
        }
        return try await get("flights/search?query=\(escapedQuery)&max_pages=1")
    }

    /// The Track tab's position query: the airborne flight matching one callsign.
    func aircraft(callsign: String) async throws -> AircraftResponse {
        let query = "-idents \(callsign)"
        guard let escapedQuery = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw AeroAPIError.badRequest
        }
        return try await get("flights/search?query=\(escapedQuery)&max_pages=1")
    }

    /// Fetches and picks the flight to track for a flight number or callsign.
    func flight(ident: String) async throws -> AeroFlight? {
        // ident_type=designator forces interpretation as a flight number, not
        // a registration (avoiding N-register misreads). max_pages=1 caps the
        // billable result sets.
        let query = "flights/\(escaped(ident))?ident_type=designator&max_pages=1"
        let response: AeroFlightResponse = try await get(query)
        return AeroFlightPicker.pick(from: response)
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var attempt = 0

        while true {
            try Task.checkCancellation()
            try await limiter.waitForTurn()

            do {
                return try await perform(path: path)
            } catch let error as AeroAPIError {
                guard let delay = try retryDelay(for: error, attempt: attempt) else { throw error }
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    private func perform<T: Decodable>(path: String) async throws -> T {
        // No key means every request is a guaranteed 401. Fail before the round trip so the UI can
        // say "no key" immediately rather than after a timeout.
        guard !apiKey.isEmpty else { throw AeroAPIError.unauthorized }

        guard let url = URL(string: path, relativeTo: Self.baseURL) else {
            throw AeroAPIError.badRequest
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-apikey")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AeroAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AeroAPIError.badRequest
        }

        switch http.statusCode {
        case 200:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw AeroAPIError.decoding(error.localizedDescription)
            }
        case 401, 403:
            // Bad or missing key. Distinct case so the UI can say exactly this.
            throw AeroAPIError.unauthorized
        case 404:
            throw AeroAPIError.notFound
        case 429:
            await limiter.backOff(rateLimitBackoff)
            throw AeroAPIError.rateLimited
        default:
            throw AeroAPIError.server(status: http.statusCode)
        }
    }

    private func retryDelay(for error: AeroAPIError, attempt: Int) throws -> Duration? {
        switch error {
        case .rateLimited:
            return rateLimitBackoff
        case .transport, .server:
            return attempt < retryDelays.count ? retryDelays[attempt] : nil
        case .unauthorized, .notFound, .decoding, .badRequest:
            return nil
        }
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

/// Errors surfaced by the AeroAPI layer. Separate from `SkyWatchError` so the
/// Track tab can explain itself ("invalid key") without touching the scan
/// loop's error handling.
enum AeroAPIError: Error, Equatable {
    case unauthorized
    case notFound
    case rateLimited
    case transport(String)
    case server(status: Int)
    case decoding(String)
    case badRequest

    /// How the scan loop's error banner should describe this. `notFound` and `badRequest` are our
    /// own mistakes rather than the wearer's, so they surface as a plain server fault.
    var scanError: SkyWatchError {
        switch self {
        case .unauthorized: .unauthorized
        case .rateLimited: .rateLimited
        case .transport: .offline
        case .server(let status): .server(status: status)
        case .decoding(let message): .decoding(underlying: message)
        case .notFound: .server(status: 404)
        case .badRequest: .server(status: 400)
        }
    }
}
