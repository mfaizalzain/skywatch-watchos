import Foundation

/// Cached origin → destination lookups for arbitrary aircraft callsigns.
///
/// The radar/detail screens show any nearby aircraft, and only FlightAware
/// knows their routes — but AeroAPI is metered (~$0.005 per `flights/{ident}`
/// query), so blind lookups per detail-screen open would burn the monthly
/// allowance fast. This caches one result per callsign for an hour: an
/// aircraft's route doesn't change mid-flight, and re-opening the same
/// aircraft repeatedly costs one query.
actor AeroRouteCache {
    static let shared = AeroRouteCache()

    private let client: AeroAPIClient?
    private var cache: [String: (route: String, fetchedAt: Date)] = [:]
    /// Routes don't change while an aircraft is in the air; an hour keeps
    /// repeated views free without ever showing a stale route.
    private let ttl: TimeInterval = 60 * 60

    init(client: AeroAPIClient? = AeroAPIClient.hasConfiguredKey ? AeroAPIClient() : nil) {
        self.client = client
    }

    /// "KUL → SYD"-style route for a callsign (e.g. "MAS123"), or nil when
    /// the layer is unavailable, the flight is unknown, or it has no route.
    func route(forCallsign callsign: String) async -> String? {
        guard let client else { return nil }
        let key = callsign.uppercased()

        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < ttl {
            return cached.route
        }

        guard let flight = try? await client.flight(ident: callsign) else { return nil }
        guard let origin = flight.origin, let destination = flight.destination else { return nil }

        let route = "\(origin.displayLabel) → \(destination.displayLabel)"
        cache[key] = (route, Date())
        return route
    }
}
