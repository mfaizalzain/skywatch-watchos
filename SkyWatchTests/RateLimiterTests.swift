import Foundation
import Testing

/// The rate limit is a correctness requirement, not an optimisation — these tests are the proof.
@Suite("Rate limiter")
struct RateLimiterTests {
    @Test("Sequential calls are spaced by at least the minimum interval")
    func sequentialSpacing() async throws {
        let limiter = RateLimiter(minimumInterval: .milliseconds(1200))
        let clock = ContinuousClock()

        var timestamps: [ContinuousClock.Instant] = []
        for _ in 0..<3 {
            try await limiter.waitForTurn()
            timestamps.append(clock.now)
        }

        for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
            // A small tolerance for the clock read happening just before the sleep resolves.
            #expect(previous.duration(to: next) >= .milliseconds(1190))
        }
    }

    @Test("Concurrent callers are serialised, not batched")
    func concurrentCallersSerialise() async throws {
        let limiter = RateLimiter(minimumInterval: .milliseconds(1200))
        let recorder = TimestampRecorder()
        let clock = ContinuousClock()

        // This is the crown-spinning case: several requests asked for at once.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await limiter.waitForTurn()
                    await recorder.record(clock.now)
                }
            }
            try await group.waitForAll()
        }

        let timestamps = await recorder.sorted()
        #expect(timestamps.count == 4)
        for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
            #expect(previous.duration(to: next) >= .milliseconds(1190))
        }
    }

    @Test("The first call does not wait")
    func firstCallIsImmediate() async throws {
        let limiter = RateLimiter(minimumInterval: .seconds(5))
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            try await limiter.waitForTurn()
        }
        #expect(elapsed < .milliseconds(100))
    }

    @Test("A 429 back-off pushes the next slot out")
    func backOffDelaysNextCall() async throws {
        let limiter = RateLimiter(minimumInterval: .milliseconds(10))
        let clock = ContinuousClock()

        try await limiter.waitForTurn()
        await limiter.backOff(.milliseconds(600))

        let elapsed = try await clock.measure {
            try await limiter.waitForTurn()
        }
        #expect(elapsed >= .milliseconds(550))
    }

    @Test("A cancelled wait throws instead of firing a request")
    func cancellationIsHonoured() async throws {
        let limiter = RateLimiter(minimumInterval: .seconds(30))
        try await limiter.waitForTurn()

        let task = Task {
            try await limiter.waitForTurn()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}

/// Collects timestamps from concurrent tasks without a data race.
private actor TimestampRecorder {
    private var timestamps: [ContinuousClock.Instant] = []

    func record(_ instant: ContinuousClock.Instant) {
        timestamps.append(instant)
    }

    func sorted() -> [ContinuousClock.Instant] {
        timestamps.sorted()
    }
}
