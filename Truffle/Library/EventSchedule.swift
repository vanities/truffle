import Foundation

/// When an occasional touch happens (Santa's flyby, a fireworks show, a rainbow), as a pure function of
/// the clock: the backdrop stores nothing, and every frame agrees on where things are.
///
/// Time is cut into windows of `period` seconds with one event in each, starting somewhere in the
/// window's first `wander` seconds, so they come about once a period without ticking like a metronome.
struct EventSchedule: Equatable, Sendable {
    let period: TimeInterval
    let duration: TimeInterval
    var wander: TimeInterval = 0
    /// Where the windows start counting. The debug launch arguments move it so one starts right away.
    var origin: TimeInterval = 0

    struct Occurrence: Equatable, Sendable {
        /// Which event, for its look (direction, height, colors).
        let index: Int
        /// 0 at the start, up to 1 at the end.
        let progress: Double
        /// Seconds since it started.
        let elapsed: TimeInterval
    }

    func occurrence(at time: TimeInterval) -> Occurrence? {
        let since = time - origin
        let index = Int((since / period).rounded(.down))
        let elapsed = since - start(of: index)
        guard elapsed >= 0, elapsed < duration else { return nil }
        return Occurrence(index: index, progress: elapsed / duration, elapsed: elapsed)
    }

    /// How many events have run by `time`, the one under way counted by how far along it is (through
    /// `easing`). It climbs by 1 over each event and holds between them, so whatever it moves (the wind's
    /// leaves) never snaps back.
    func runningCount(at time: TimeInterval, easing: (Double) -> Double = { $0 }) -> Double {
        let since = time - origin
        let index = Int((since / period).rounded(.down))
        let elapsed = since - start(of: index)
        if elapsed < 0 { return Double(index) }
        if elapsed >= duration { return Double(index + 1) }
        return Double(index) + easing(elapsed / duration)
    }

    /// When event `index` starts, in seconds after `origin`.
    func start(of index: Int) -> TimeInterval {
        let room = max(0, min(wander, period - duration))
        return Double(index) * period + room * Self.unit(index)
    }

    /// A stable number in 0..<1 for `index` (splitmix64), so each event keeps its own look.
    static func unit(_ index: Int, salt: Int = 0) -> Double {
        var x = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(salt)) &* 0xD1B5_4A32_D192_ED03
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }
}

extension EventSchedule {
    /// Santa's sleigh: about once a minute.
    static let flyby = EventSchedule(period: 64, duration: 9, wander: 24)
    /// A short show of a few bursts: often on the Fourth, now and then at New Year.
    static let fourthFireworks = EventSchedule(period: 24, duration: 6.5, wander: 8)
    static let newYearFireworks = EventSchedule(period: 36, duration: 6.5, wander: 12)
    static let rainbow = EventSchedule(period: 46, duration: 5, wander: 14)
    /// A gust of wind through the leaves: every 20 seconds or so.
    static let gust = EventSchedule(period: 20, duration: 4.5, wander: 9)
    /// A bat past the moon: about once a minute.
    static let bat = EventSchedule(period: 55, duration: 6.5, wander: 20)
    /// A shooting star: every half minute or so, gone in a blink.
    static let shootingStar = EventSchedule(period: 28, duration: 1.1, wander: 16)

    /// For capturing an event: the first starts `delay` seconds after `now`, then one every `period`.
    static func rightAway(_ schedule: EventSchedule, now: TimeInterval, delay: TimeInterval = 2, period: TimeInterval = 14) -> EventSchedule {
        EventSchedule(period: max(period, schedule.duration + 1), duration: schedule.duration, wander: 0, origin: now + delay)
    }
}
