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

    /// Up to `count` positions, starting a new round if this one runs out.
    mutating func take<G: RandomNumberGenerator>(_ count: Int, using generator: inout G) -> [Int] {
        var positions: [Int] = []
        while positions.count < count {
            if let position = next() {
                positions.append(position)
            } else if total > 0 {
                self = ShuffleWalk(total: total, round: round + 1, using: &generator)
            } else {
                break
            }
        }
        return positions
    }

    mutating func take(_ count: Int) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return take(count, using: &generator)
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
