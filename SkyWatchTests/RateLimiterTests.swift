import Foundation
import Testing

/// The rate limit is a correctness requirement, not an optimisation — these tests are the proof.
@Suite("Rate limiter")
struct RateLimiterTests {
    /// Builds a limiter whose "sleep" records the duration it was asked to wait instead of
    /// actually waiting. The guarantee we care about is the requested spacing, not wall-clock
    /// accuracy — and the simulator's clock makes real-time assertions flaky.
    private func recordingLimiter(
        interval: Duration = .milliseconds(1200)
    ) -> (RateLimiter, SleepRecorder) {
        let recorder = SleepRecorder()
        let limiter = RateLimiter(minimumInterval: interval) { duration in
            await recorder.record(duration)
        }
        return (limiter, recorder)
    }

    @Test("Sequential calls are spaced by at least the minimum interval")
    func sequentialSpacing() async throws {
        let (limiter, recorder) = recordingLimiter()

        for _ in 0..<3 {
            try await limiter.waitForTurn()
        }

        let waits = await recorder.waits
        // Three calls, two of them had to wait; each wait is a full interval.
        #expect(waits.count == 2)
        for wait in waits {
            #expect(wait >= .milliseconds(1190))
        }
    }

    @Test("Concurrent callers are serialised, not batched")
    func concurrentCallersSerialise() async throws {
        let (limiter, recorder) = recordingLimiter()

        // This is the crown-spinning case: several requests asked for at once.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await limiter.waitForTurn()
                }
            }
            try await group.waitForAll()
        }

        let waits = await recorder.waits
        // Four callers, three of them had to wait; each waited a full interval, and the waits
        // are cumulative (the third caller waited for two slots, the fourth for three).
        #expect(waits.count == 3)
        let sorted = waits.sorted()
        #expect(sorted[0] >= .milliseconds(1190))
        #expect(sorted[1] >= .milliseconds(2390))
        #expect(sorted[2] >= .milliseconds(3590))
    }

    @Test("The first call does not wait")
    func firstCallIsImmediate() async throws {
        let (limiter, recorder) = recordingLimiter(interval: .seconds(5))

        try await limiter.waitForTurn()

        let waits = await recorder.waits
        #expect(waits.isEmpty)
    }

    @Test("A 429 back-off pushes the next slot out")
    func backOffDelaysNextCall() async throws {
        let (limiter, recorder) = recordingLimiter(interval: .milliseconds(10))

        try await limiter.waitForTurn()
        await limiter.backOff(.milliseconds(600))
        try await limiter.waitForTurn()

        let waits = await recorder.waits
        // The back-off extends the slot past what the interval alone would have asked for.
        #expect(waits.count == 1)
        #expect(waits[0] >= .milliseconds(550))
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

/// Records the durations a limiter was asked to sleep, so tests assert on the spacing logic
/// without depending on a real clock.
private actor SleepRecorder {
    private var recorded: [Duration] = []

    func record(_ duration: Duration) {
        recorded.append(duration)
    }

    var waits: [Duration] { recorded }
}
