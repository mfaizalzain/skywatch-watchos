import Foundation
import Testing

@Suite("Target merge")
struct MergeTests {
    private let merger = TargetMerger()
    private let observer = Coordinate(latitude: 37.0, longitude: -122.0)

    /// One aircraft, `northNM` north of the observer. The position is stamped fresh so merges
    /// compare distances rather than staleness.
    private func aircraft(
        id: String,
        northNM: Double,
        track: Double = 180,
        speed: Double = 300
    ) throws -> Aircraft {
        let latitude = 37.0 + northNM / 60.0
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return try Fixtures.decodeAircraft("""
        {"fa_flight_id":"\(id)","ident":"TEST\(id.prefix(2))",
         "last_position":{"altitude":100,"altitude_change":"-","groundspeed":\(Int(speed)),
          "heading":\(Int(track)),"latitude":\(latitude),"longitude":-122.0,
          "timestamp":"\(timestamp)","update_type":"A"}}
        """)
    }

    @Test("A new target appears with no trail")
    func targetAppears() throws {
        let merged = merger.merge(existing: [], response: [try aircraft(id: "aaa111", northNM: 10)], observer: observer)

        #expect(merged.count == 1)
        let target = try #require(merged.first)
        #expect(target.id == "aaa111")
        #expect(target.trail.isEmpty)
        #expect(target.missedCycles == 0)
        #expect(abs(target.distanceNM - 10) < 0.1)
        #expect(abs(target.bearingDegrees) < 0.1)
    }

    @Test("A moving target keeps its identity and grows a trail")
    func targetMoves() throws {
        var targets = merger.merge(existing: [], response: [try aircraft(id: "aaa111", northNM: 10)], observer: observer)
        let firstSeen = try #require(targets.first).firstSeen

        targets = merger.merge(existing: targets, response: [try aircraft(id: "aaa111", northNM: 8)], observer: observer)
        targets = merger.merge(existing: targets, response: [try aircraft(id: "aaa111", northNM: 6)], observer: observer)

        let target = try #require(targets.first)
        #expect(targets.count == 1)
        #expect(target.trail.count == 2)
        #expect(abs(target.distanceNM - 6) < 0.1)
        // The tail runs oldest-first, so the first point is where it started.
        #expect(target.trail.first!.coordinate.latitude > target.trail.last!.coordinate.latitude)
        #expect(target.firstSeen == firstSeen)
    }

    @Test("The trail is capped at three samples")
    func trailIsCapped() throws {
        var targets: [TrackedTarget] = []
        for step in stride(from: 20.0, to: 2.0, by: -2.0) {
            targets = merger.merge(existing: targets, response: [try aircraft(id: "aaa111", northNM: step)], observer: observer)
        }

        #expect(try #require(targets.first).trail.count == TargetMerger.trailLength)
    }

    @Test("A stationary target does not accumulate duplicate trail points")
    func stationaryTargetHasNoTrail() throws {
        var targets: [TrackedTarget] = []
        for _ in 0..<4 {
            targets = merger.merge(existing: targets, response: [try aircraft(id: "aaa111", northNM: 10)], observer: observer)
        }

        #expect(try #require(targets.first).trail.isEmpty)
    }

    @Test("A target missing for one cycle is kept and marked fading")
    func missingForOneCycle() throws {
        var targets = merger.merge(existing: [], response: [try aircraft(id: "aaa111", northNM: 10)], observer: observer)
        targets = merger.merge(existing: targets, response: [], observer: observer)

        let target = try #require(targets.first)
        #expect(targets.count == 1)
        #expect(target.missedCycles == 1)
        #expect(target.isFading)
    }

    @Test("A target that comes back has its miss count cleared")
    func targetReturns() throws {
        var targets = merger.merge(existing: [], response: [try aircraft(id: "aaa111", northNM: 10)], observer: observer)
        targets = merger.merge(existing: targets, response: [], observer: observer)
        targets = merger.merge(existing: targets, response: [try aircraft(id: "aaa111", northNM: 9)], observer: observer)

        let target = try #require(targets.first)
        #expect(target.missedCycles == 0)
        #expect(target.isFading == false)
    }

    @Test("A target missing for two consecutive cycles is dropped")
    func missingForTwoCycles() throws {
        var targets = merger.merge(existing: [], response: [try aircraft(id: "aaa111", northNM: 10)], observer: observer)
        targets = merger.merge(existing: targets, response: [], observer: observer)
        targets = merger.merge(existing: targets, response: [], observer: observer)

        #expect(targets.isEmpty)
    }

    @Test("A detail lookup does not age out the rest of the sky")
    func detailMergeDoesNotPenalise() throws {
        let scan = [try aircraft(id: "aaa111", northNM: 10), try aircraft(id: "bbb222", northNM: 15)]
        var targets = merger.merge(existing: [], response: scan, observer: observer)

        // Two single-aircraft merges in a row would otherwise drop everything else.
        for _ in 0..<2 {
            targets = merger.merge(
                existing: targets,
                response: [try aircraft(id: "aaa111", northNM: 9)],
                observer: observer,
                penalizeMissing: false
            )
        }

        #expect(targets.count == 2)
        #expect(targets.allSatisfy { $0.missedCycles == 0 })
    }

    @Test("Results come back sorted by distance")
    func sortedByDistance() throws {
        let response = [
            try aircraft(id: "far", northNM: 30),
            try aircraft(id: "near", northNM: 3),
            try aircraft(id: "mid", northNM: 12)
        ]
        let targets = merger.merge(existing: [], response: response, observer: observer)

        #expect(targets.map(\.id) == ["near", "mid", "far"])
    }

    @Test("Targets with no flight id are not tracked")
    func idlessTargetsIgnored() throws {
        let anonymous = try Fixtures.decodeAircraft("""
        {"ident":"GHOST1","last_position":{"latitude":37.1,"longitude":-122.0,
         "timestamp":"2023-02-05T21:47:51Z","update_type":"A"}}
        """)
        let targets = merger.merge(existing: [], response: [anonymous], observer: observer)

        #expect(targets.isEmpty)
    }

    @Test("Targets with no position are not tracked")
    func positionlessTargetsIgnored() throws {
        let heardOnly = try Fixtures.decodeAircraft(#"{"fa_flight_id":"aaa111"}"#)
        let targets = merger.merge(existing: [], response: [heardOnly], observer: observer)

        #expect(targets.isEmpty)
    }

    @Test("Closest approach is carried onto the target")
    func closestApproachAttached() throws {
        // 10 nm north tracking due south at 360 kt: 100 seconds to overhead.
        let targets = merger.merge(
            existing: [],
            response: [try aircraft(id: "aaa111", northNM: 10, track: 180, speed: 360)],
            observer: observer
        )

        let first = try #require(targets.first)
        let approach = try #require(first.closestApproach)
        #expect(abs(approach.timeToClosestApproach - 100) < 2)
        #expect(approach.minimumDistanceNM < 0.2)
    }

    @Test("The alerted flag survives a refresh so a target only buzzes once")
    func alertFlagSurvives() throws {
        var targets = merger.merge(existing: [], response: [try aircraft(id: "aaa111", northNM: 2)], observer: observer)
        targets[0].hasAlerted = true

        targets = merger.merge(existing: targets, response: [try aircraft(id: "aaa111", northNM: 1.5)], observer: observer)

        #expect(try #require(targets.first).hasAlerted)
    }

    @Test("A sky larger than the cap keeps only the nearest targets")
    func skyIsCappedToNearest() throws {
        let many = try (1...80).map { try aircraft(id: String(format: "a%04x", $0), northNM: Double($0)) }
        let targets = merger.merge(existing: [], response: many, observer: observer)

        #expect(targets.count == merger.maxTrackedTargets)
        #expect(targets.map(\.distanceNM).sorted() == targets.map(\.distanceNM))
        #expect(targets.last!.distanceNM < 61)
    }

    @Test("A detail lookup cannot grow the tracked set past the cap")
    func detailMergeRespectsCap() throws {
        let many = try (1...70).map { try aircraft(id: String(format: "a%04x", $0), northNM: Double($0)) }
        var targets = merger.merge(existing: [], response: many, observer: observer)

        // A new aircraft arrives via the detail path, which does not penalise anyone missing.
        let newcomer = try aircraft(id: "b0001", northNM: 40)
        targets = merger.merge(existing: targets, response: [newcomer], observer: observer, penalizeMissing: false)

        #expect(targets.count == merger.maxTrackedTargets)
        #expect(targets.contains { $0.id == "b0001" })
    }

    @Test("A sky within the cap is left untouched")
    func skyUnderCapIsUnchanged() throws {
        let few = try (1...20).map { try aircraft(id: String(format: "a%04x", $0), northNM: Double($0)) }
        let targets = merger.merge(existing: [], response: few, observer: observer)

        #expect(targets.count == 20)
    }
}
