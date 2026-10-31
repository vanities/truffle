import Foundation

/// A true shuffle over N positions: a uniformly random order, every position once before any
/// position twice, and nothing weighted (no ratings, no play counts, no artist spacing). That's the
/// point: Plex's "smart shuffle" favors highly rated and popular tracks.
///
/// Positions index the library sorted by id (`sort=id`), so the songs added later get the new,
/// higher positions. The walk is saved, so a round through a 17,000-song library carries on across
/// drives instead of starting over each time.
struct ShuffleWalk: Codable, Sendable, Equatable {
    /// Positions still to play, drawn from the end.
    private(set) var remaining: [Int32]
    /// How many positions the library had when the walk last grew or shrank.
    private(set) var total: Int
    /// Played this round.
    private(set) var played: Int
    private(set) var round: Int

    init<G: RandomNumberGenerator>(total: Int, round: Int = 1, using generator: inout G) {
        self.total = max(0, total)
        self.played = 0
        self.round = round
        var order = (0..<Int32(clamping: self.total)).map { $0 }
        order.shuffle(using: &generator)
        remaining = order
    }

    init(total: Int, round: Int = 1) {
        var generator = SystemRandomNumberGenerator()
        self.init(total: total, round: round, using: &generator)
    }

    var isExhausted: Bool { remaining.isEmpty }

    /// The next position, or nil when the round is over (the caller starts a new one).
    mutating func next() -> Int? {
        guard let position = remaining.popLast() else { return nil }
        played += 1
        return Int(position)
    }

    /// The next position that isn't held back (out-of-season holiday music), or nil when only held-back
    /// ones are left. Each held-back position it passes goes back among the ones still to play, at a
    /// random place, so it's still in this round, nowhere in particular, when it's wanted. Everything
    /// else keeps its order: holding some back changes nothing about the rest of the shuffle.
    mutating func next<G: RandomNumberGenerator>(holdingBack heldBack: Set<Int32>, using generator: inout G) -> Int? {
        guard !heldBack.isEmpty else { return next() }
        guard let index = remaining.lastIndex(where: { !heldBack.contains($0) }) else { return nil }
        let position = remaining[index]
        let passed = Array(remaining[(index + 1)...])
        remaining.removeSubrange(index...)
        for held in passed {
            remaining.insert(held, at: Int.random(in: 0...remaining.count, using: &generator))
        }
        played += 1
        return Int(position)
    }

    /// Up to `count` positions, starting a new round if this one runs out. Held-back positions are
    /// passed over (see `next(holdingBack:using:)`); a round with only those left is over.
    mutating func take<G: RandomNumberGenerator>(_ count: Int, holdingBack heldBack: Set<Int32> = [],
                                                using generator: inout G) -> [Int] {
        var positions: [Int] = []
        var freshRound = false
        while positions.count < count {
            if let position = next(holdingBack: heldBack, using: &generator) {
                positions.append(position)
                freshRound = false
            } else if total > 0, !freshRound {
                self = ShuffleWalk(total: total, round: round + 1, using: &generator)
                freshRound = true
            } else {
                break
            }
        }
        return positions
    }

    mutating func take(_ count: Int, holdingBack heldBack: Set<Int32> = []) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return take(count, holdingBack: heldBack, using: &generator)
    }

    /// A position just drawn goes back into the round at a random place, uncounted: its song turned
    /// out to be held back (found out of season when it was fetched). Ignored once the walk is on
    /// another round, which has the song anyway.
    mutating func putBack<G: RandomNumberGenerator>(_ position: Int, drawnInRound drawnIn: Int, using generator: inout G) {
        let value = Int32(clamping: position)
        guard drawnIn == round, (0..<total).contains(position), !remaining.contains(value) else { return }
        remaining.insert(value, at: Int.random(in: 0...remaining.count, using: &generator))
        played = max(0, played - 1)
    }

    mutating func putBack(_ position: Int, drawnInRound drawnIn: Int) {
        var generator = SystemRandomNumberGenerator()
        putBack(position, drawnInRound: drawnIn, using: &generator)
    }

    /// The library changed size. New songs (new, higher positions) land at uniformly random spots
    /// among the ones still to play; positions past a shrunken end are dropped.
    mutating func resize<G: RandomNumberGenerator>(to newTotal: Int, using generator: inout G) {
        let newTotal = max(0, newTotal)
        if newTotal > total {
            for position in total..<newTotal {
                remaining.insert(Int32(clamping: position), at: Int.random(in: 0...remaining.count, using: &generator))
            }
        } else if newTotal < total {
            remaining.removeAll { Int($0) >= newTotal }
        }
        total = newTotal
    }

    mutating func resize(to newTotal: Int) {
        var generator = SystemRandomNumberGenerator()
        resize(to: newTotal, using: &generator)
    }
}
