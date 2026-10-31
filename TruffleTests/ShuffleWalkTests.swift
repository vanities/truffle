import XCTest
@testable import Truffle

/// A seeded generator so the statistical tests are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class ShuffleWalkTests: XCTestCase {
    func testEverySongOncePerRound() {
        var generator = SeededGenerator(seed: 1)
        var walk = ShuffleWalk(total: 1000, using: &generator)
        var seen: [Int] = []
        while let position = walk.next() { seen.append(position) }
        XCTAssertEqual(seen.count, 1000)
        XCTAssertEqual(Set(seen), Set(0..<1000), "every position exactly once before any repeat")
        XCTAssertNotEqual(seen, Array(0..<1000))
    }

    func testEachSongIsEquallyLikelyToComeFirst() {
        // 60,000 walks over 6 songs: a weighted shuffle would skew these counts.
        var generator = SeededGenerator(seed: 42)
        var firsts = [Int](repeating: 0, count: 6)
        for _ in 0..<60_000 {
            var walk = ShuffleWalk(total: 6, using: &generator)
            firsts[walk.next()!] += 1
        }
        let expected = 10_000.0
        let chiSquare = firsts.reduce(0.0) { $0 + pow(Double($1) - expected, 2) / expected }
        XCTAssertLessThan(chiSquare, 20.5, "chi-square for 5 degrees of freedom at p=0.001; counts: \(firsts)")
    }

    func testEveryOrderOfThreeSongsIsEquallyLikely() {
        var generator = SeededGenerator(seed: 7)
        var orders: [[Int]: Int] = [:]
        for _ in 0..<60_000 {
            var walk = ShuffleWalk(total: 3, using: &generator)
            orders[[walk.next()!, walk.next()!, walk.next()!], default: 0] += 1
        }
        XCTAssertEqual(orders.count, 6)
        let chiSquare = orders.values.reduce(0.0) { $0 + pow(Double($1) - 10_000, 2) / 10_000 }
        XCTAssertLessThan(chiSquare, 20.5, "\(orders)")
    }

    func testANewRoundStartsWhenOneEnds() {
        var generator = SeededGenerator(seed: 3)
        var walk = ShuffleWalk(total: 4, using: &generator)
        let first = walk.take(4, using: &generator)
        XCTAssertEqual(Set(first), Set(0..<4))
        XCTAssertEqual(walk.round, 1)
        let more = walk.take(2, using: &generator)
        XCTAssertEqual(walk.round, 2)
        XCTAssertEqual(walk.played, 2)
        XCTAssertEqual(more.count, 2)
    }

    func testNewSongsJoinTheRoundStillToPlay() {
        var generator = SeededGenerator(seed: 9)
        var walk = ShuffleWalk(total: 10, using: &generator)
        let played = walk.take(4, using: &generator)
        walk.resize(to: 15, using: &generator)
        var rest: [Int] = []
        while let position = walk.next() { rest.append(position) }
        XCTAssertEqual(Set(played + rest), Set(0..<15), "added songs play this round, nothing repeats")
        XCTAssertEqual(rest.count, 11)
    }

    func testSongsRemovedFromTheEndAreDropped() {
        var generator = SeededGenerator(seed: 11)
        var walk = ShuffleWalk(total: 10, using: &generator)
        walk.resize(to: 6, using: &generator)
        var rest: [Int] = []
        while let position = walk.next() { rest.append(position) }
        XCTAssertEqual(Set(rest), Set(0..<6))
    }

    // MARK: - Holding back (holiday music out of season)

    func testHoldingSomeBackLeavesTheRestInTheSameOrder() {
        var generator = SeededGenerator(seed: 21)
        let walk = ShuffleWalk(total: 200, using: &generator)
        let held: Set<Int32> = [3, 50, 51, 120, 199]
        var plain = walk
        var holding = walk
        var everything: [Int] = []
        while let position = plain.next() { everything.append(position) }
        var kept: [Int] = []
        while let position = holding.next(holdingBack: held, using: &generator) { kept.append(position) }
        XCTAssertEqual(kept, everything.filter { !held.contains(Int32($0)) }, "the rest of the shuffle doesn't move")
        XCTAssertEqual(Set(holding.remaining), held, "the held-back songs are still in the round")
        XCTAssertEqual(holding.round, 1)
    }

    func testHeldBackSongsPlayInTheSameRoundWhenTheSeasonComes() {
        var generator = SeededGenerator(seed: 22)
        var walk = ShuffleWalk(total: 30, using: &generator)
        let held: Set<Int32> = [0, 1, 2]
        let outOfSeason = walk.take(20, holdingBack: held, using: &generator)
        XCTAssertFalse(outOfSeason.contains { held.contains(Int32($0)) })
        let inSeason = walk.take(10, using: &generator)
        XCTAssertEqual(walk.round, 1)
        XCTAssertEqual(outOfSeason.count + inSeason.count, 30)
        XCTAssertEqual(Set(outOfSeason + inSeason), Set(0..<30), "every song once, the held-back ones included")
    }

    func testHeldBackSongsLandAnywhereInWhatsLeft() {
        // 20,000 walks over 10 songs: hold one back for 5 draws, then let it play. Where it comes up among
        // the 5 left should be uniform, not bunched at the front where it kept getting passed over.
        var generator = SeededGenerator(seed: 23)
        var places = [Int](repeating: 0, count: 5)
        for _ in 0..<20_000 {
            var walk = ShuffleWalk(total: 10, using: &generator)
            _ = walk.take(5, holdingBack: [7], using: &generator)
            var rest: [Int] = []
            while let position = walk.next() { rest.append(position) }
            places[rest.firstIndex(of: 7)!] += 1
        }
        let chiSquare = places.reduce(0.0) { $0 + pow(Double($1) - 4_000, 2) / 4_000 }
        XCTAssertLessThan(chiSquare, 18.47, "chi-square for 4 degrees of freedom at p=0.001; places: \(places)")
    }

    func testARoundWithOnlyHeldBackSongsLeftIsOver() {
        var generator = SeededGenerator(seed: 24)
        var walk = ShuffleWalk(total: 4, using: &generator)
        XCTAssertEqual(walk.take(2, holdingBack: [0, 1, 2, 3], using: &generator), [], "no endless new rounds")
        var mostly = ShuffleWalk(total: 4, using: &generator)
        XCTAssertEqual(mostly.take(3, holdingBack: [0, 1, 2], using: &generator), [3, 3, 3], "one song a round")
        XCTAssertEqual(mostly.round, 3)
    }

    func testASongPutBackPlaysLaterThisRound() {
        var generator = SeededGenerator(seed: 25)
        var walk = ShuffleWalk(total: 12, using: &generator)
        let first = walk.take(3, using: &generator)
        walk.putBack(first[1], drawnInRound: 1, using: &generator)
        walk.putBack(first[1], drawnInRound: 1, using: &generator)
        XCTAssertEqual(walk.played, 2, "put back once, however often it's asked")
        var rest: [Int] = []
        while let position = walk.next() { rest.append(position) }
        XCTAssertEqual(rest.count, 10)
        XCTAssertEqual(Set([first[0], first[2]] + rest), Set(0..<12))
    }

    func testPuttingBackLeavesANewRoundAlone() {
        var generator = SeededGenerator(seed: 26)
        var walk = ShuffleWalk(total: 3, using: &generator)
        let drawn = walk.take(4, using: &generator)
        XCTAssertEqual(walk.round, 2)
        walk.putBack(drawn[0], drawnInRound: 1, using: &generator)
        XCTAssertEqual(walk.played, 1)
        XCTAssertEqual(walk.remaining.count, 2, "round 2 has that song already")
    }

    func testTheWalkSurvivesBeingSaved() throws {
        var walk = ShuffleWalk(total: 50)
        _ = walk.take(10)
        let restored = try JSONDecoder().decode(ShuffleWalk.self, from: JSONEncoder().encode(walk))
        XCTAssertEqual(restored, walk)
        XCTAssertEqual(restored.played, 10)
    }
}
