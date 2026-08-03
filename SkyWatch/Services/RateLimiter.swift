import Foundation

/// Serialises access to the API and guarantees a minimum gap between requests.
///
/// airplanes.live allows one request per second. The limiter reserves the next slot *before* it
/// suspends, so concurrent callers queue up behind each other instead of all measuring the same
/// idle `lastRequest` and firing together. That property is what makes the guarantee hold when the
/// user spins the Digital Crown.
actor RateLimiter {
    /// 1.2 s rather than 1.0 s: the limit is enforced server-side against arrival time, and the
    /// margin absorbs scheduling jitter without ever crossing the line.
    static let defaultInterval: Duration = .milliseconds(1200)

    private let minimumInterval: Duration
    private let clock = ContinuousClock()
    private var nextAvailableSlot: ContinuousClock.Instant?

    init(minimumInterval: Duration = RateLimiter.defaultInterval) {
        self.minimumInterval = minimumInterval
    }

    /// Suspends until this caller's slot comes up. Throws `CancellationError` if the task is
    /// cancelled while it waits.
    func waitForTurn() async throws {
        let now = clock.now
        let slot = max(now, nextAvailableSlot ?? now)
        nextAvailableSlot = slot.advanced(by: minimumInterval)

        if slot > now {
            try await clock.sleep(until: slot, tolerance: .zero)
        } else {
            // Still a cancellation point, so a cancelled scan doesn't sneak one last request out.
            try Task.checkCancellation()
        }
    }

    /// Pushes every queued caller back — used after an HTTP 429 so the app visibly slows down
    /// instead of hammering a server that has already said no.
    func backOff(_ duration: Duration) {
        let resume = clock.now.advanced(by: duration)
        nextAvailableSlot = max(nextAvailableSlot ?? resume, resume)
    }
}
