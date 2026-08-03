import Foundation
import os

/// The only thing in this app that touches the network, and the only host it ever talks to.
actor AirplanesLiveClient {
    static let baseURL = URL(string: "https://api.airplanes.live/v2/")!
    static let maximumRadiusNM = 250.0

    private let session: URLSession
    private let limiter: RateLimiter
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "com.fmz.skywatch", category: "api")

    /// Two retries: 2 s then 5 s, plus jitter so a flapping connection doesn't produce a
    /// synchronised burst.
    private let retryDelays: [Duration] = [.seconds(2), .seconds(5)]
    private let rateLimitBackoff: Duration = .seconds(10)

    init(limiter: RateLimiter = RateLimiter(), session: URLSession? = nil) {
        self.limiter = limiter
        self.session = session ?? Self.makeSession()
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

    // MARK: - Endpoints

    /// The scan query. `radiusNM` is clamped to the documented maximum.
    func aircraft(near coordinate: Coordinate, radiusNM: Double) async throws -> AircraftResponse {
        let radius = min(max(radiusNM, 1), Self.maximumRadiusNM)
        let latitude = String(format: "%.5f", coordinate.latitude)
        let longitude = String(format: "%.5f", coordinate.longitude)
        return try await get("point/\(latitude)/\(longitude)/\(Int(radius.rounded()))")
    }

    /// Detail-screen refresh. Goes through the same limiter as everything else.
    func aircraft(hex: String) async throws -> AircraftResponse {
        try await get("hex/\(escaped(hex))")
    }

    func aircraft(callsign: String) async throws -> AircraftResponse {
        try await get("callsign/\(escaped(callsign))")
    }

    func aircraft(registration: String) async throws -> AircraftResponse {
        try await get("reg/\(escaped(registration))")
    }

    func aircraft(icaoType: String) async throws -> AircraftResponse {
        try await get("type/\(escaped(icaoType))")
    }

    func aircraft(squawk: String) async throws -> AircraftResponse {
        try await get("squawk/\(escaped(squawk))")
    }

    func military() async throws -> AircraftResponse {
        try await get("mil")
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> AircraftResponse {
        var attempt = 0

        while true {
            try Task.checkCancellation()
            try await limiter.waitForTurn()

            do {
                return try await perform(path: path)
            } catch let error as SkyWatchError {
                guard let delay = try retryDelay(for: error, attempt: attempt) else { throw error }
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    private func perform(path: String) async throws -> AircraftResponse {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else {
            throw SkyWatchError.server(status: -1)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            // A cancelled request is not an outage: reported as one, the retry loop would treat it
            // as transport failure and fire the request we just cancelled all over again.
            if error.code == .cancelled { throw CancellationError() }
            throw Self.mapped(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SkyWatchError.server(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 429:
            await limiter.backOff(rateLimitBackoff)
            throw SkyWatchError.rateLimited
        default:
            throw SkyWatchError.server(status: http.statusCode)
        }

        let decoded: AircraftResponse
        do {
            decoded = try decoder.decode(AircraftResponse.self, from: data)
        } catch {
            logger.error("Decoding failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw SkyWatchError.decoding(underlying: error.localizedDescription)
        }

        for memberError in decoded.malformedMemberErrors {
            logger.warning("Skipped malformed aircraft: \(memberError, privacy: .public)")
        }
        if let apiError = decoded.apiError {
            logger.error("API message: \(apiError, privacy: .public)")
            throw SkyWatchError.apiMessage(apiError)
        }

        return decoded
    }

    /// `nil` means "don't retry". 4xx other than 429 are our fault and will fail identically next
    /// time; a rate limit is surfaced immediately so the UI can say so, and recovers on the next
    /// poll because the limiter is already holding the line.
    private func retryDelay(for error: SkyWatchError, attempt: Int) throws -> Duration? {
        guard attempt < retryDelays.count else { return nil }

        switch error {
        case .offline:
            return jittered(retryDelays[attempt])
        case .server(let status) where status >= 500:
            return jittered(retryDelays[attempt])
        case .rateLimited, .server, .decoding, .apiMessage, .locationDenied, .locationUnavailable:
            return nil
        }
    }

    private func jittered(_ duration: Duration) -> Duration {
        let seconds = Double(duration.components.seconds)
        return .milliseconds(Int((seconds + Double.random(in: 0...0.5)) * 1000))
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private static func mapped(_ error: URLError) -> SkyWatchError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .cannotFindHost, .cannotConnectToHost, .timedOut, .internationalRoamingOff:
            return .offline
        default:
            return .server(status: error.errorCode)
        }
    }
}
