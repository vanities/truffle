import Foundation

/// What to do with a stream that's waiting to play. AVPlayer decides when a song starts, and it does well
/// when the connection is good; these are the three cases where waiting on it costs the most.
///
/// Measured against scripts/demo_server.py (DEMO_FLAC=1, DEMO_AUDIO_KBPS, 2026-11-21): a FLAC arriving faster
/// than it plays starts in half a second. One arriving at 0.8 times its bitrate plays ten seconds, runs dry,
/// and then sits silent until a fifth of the song is in hand, most of a minute. A song in an MP4 with its
/// index at the end sat silent 19 s while arriving at five times its bitrate.
enum Buffering {
    enum Verdict: Equatable, Sendable {
        case wait
        /// Enough is buffered and more is arriving faster than it plays: start now.
        case start
        /// It's arriving, but slower than it plays, and the original will never keep up on this connection:
        /// play Plex's 192 kbps stream of the song instead (Data Saver's, `StreamMode.dataSaver`).
        case lighter
        /// Nothing has arrived for `patience`: the connection is dead. Find the server again and load afresh.
        case reconnect
    }

    /// What a waiting song has to show for itself.
    struct Sample: Equatable, Sendable {
        /// How long it has been waiting this time.
        var waited: TimeInterval
        /// Seconds buffered past where it will play from.
        var ahead: TimeInterval
        /// Seconds of song arriving per second, over the last few seconds; nil before there's a measure.
        var fill: Double?
        /// How long since any more of it arrived.
        var idle: TimeInterval
        /// How long it has been arriving without a break; nil is the whole wait. The rate only means anything
        /// over this: a song that got nothing for a minute and then its first half second isn't slow.
        var arriving: TimeInterval?
        /// The whole rest of the song is in.
        var complete = false
    }

    /// Arriving at least this much faster than it plays counts as keeping up, with room for a dip.
    static let keepingUp = 1.3
    /// Arriving slower than this, the song can't play through without stopping again.
    static let fallingBehind = 0.95
    /// A trickle below this is a dying connection, not a slow one: that's `reconnect`'s.
    static let trickle = 0.05
    /// With this much in hand it starts whatever the rate.
    static let plenty: TimeInterval = 30
    /// The rate is measured over a few seconds, so nothing is called slow before this.
    static let settle: TimeInterval = 4
    static let patience: TimeInterval = 10
    /// A song that went quiet is reconnected this many times, then left to AVPlayer.
    static let reconnects = 2

    /// Seconds a song needs buffered before it starts early: more after each early start, so one that ran dry
    /// isn't started on a sliver twice.
    static func needed(earlyStarts: Int) -> TimeInterval {
        min(3 * pow(2, Double(max(0, earlyStarts))), 24)
    }

    /// `canLighten`: the song is streaming its original and a lighter stream is on offer.
    static func verdict(for sample: Sample, earlyStarts: Int, canLighten: Bool) -> Verdict {
        if sample.complete, sample.ahead > 0 { return .start }
        if sample.ahead >= plenty { return .start }
        if sample.ahead >= needed(earlyStarts: earlyStarts), let fill = sample.fill, fill >= keepingUp { return .start }
        if sample.idle >= patience { return .reconnect }
        if canLighten, (sample.arriving ?? sample.waited) >= settle, let fill = sample.fill, fill > trickle, fill < fallingBehind {
            return .lighter
        }
        return .wait
    }

    /// Seconds of song per second between the oldest and newest of `ends` (when, buffered up to), or nil
    /// when they span too little time to say.
    static func fill(_ ends: [(at: TimeInterval, end: TimeInterval)]) -> Double? {
        guard let first = ends.first, let last = ends.last, last.at - first.at >= 2 else { return nil }
        return max(0, last.end - first.end) / (last.at - first.at)
    }
}

/// The connection couldn't carry an original a while ago, so new songs stream the lighter copy until it's
/// had time to change. Each time it happens again the rest doubles (5, 10, 20 minutes); a new network or a
/// new server address clears it.
struct WeakSignal: Equatable, Sendable {
    static let firstRest: TimeInterval = 5 * 60
    static let longestRest: TimeInterval = 20 * 60

    private(set) var until: Date?
    private(set) var rest: TimeInterval = firstRest

    func isWeak(at now: Date) -> Bool {
        until.map { now < $0 } ?? false
    }

    /// An original fell behind. Returns how long originals rest.
    @discardableResult
    mutating func fellBehind(at now: Date) -> TimeInterval {
        let length = rest
        until = now.addingTimeInterval(length)
        rest = min(rest * 2, Self.longestRest)
        return length
    }

    mutating func clear() {
        self = WeakSignal()
    }
}
