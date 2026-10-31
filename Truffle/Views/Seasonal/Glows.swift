import Foundation

/// How the season's lights glow: the string of bulbs, run like a light controller, and the candle in the
/// jack-o'-lantern. Like the rest of the backdrop they're functions of time, and they ease rather than
/// blink: a bulb takes a few frames to warm up or cool down, so nothing strobes (`GlowTests` holds them
/// to that).
enum LightShow {
    /// A controller's classic programs.
    enum Pattern: CaseIterable {
        /// All on, with now and then a bulb going out and coming back.
        case twinkle
        /// Light running along the string, each color in turn.
        case chase
        /// Every other bulb fading up as its neighbors fade down.
        case slowFade
        /// A soft swell rolling down the string.
        case waves
        /// The colors coming on one at a time, glowing together, then going out.
        case colorByColor
    }

    /// Seconds each pattern plays, the last `blend` of them easing into the next.
    static let length: TimeInterval = 15
    static let blend: TimeInterval = 2

    static func pattern(at time: TimeInterval) -> Pattern {
        pattern(slot: (time / length).rounded(.down))
    }

    /// How lit bulb `bulb` of `count` is at `time`, from 0 (cold glass) to 1 (full on). The bulbs take
    /// `colors` colors in turn.
    static func level(bulb: Int, of count: Int, colors: Int, at time: TimeInterval) -> Double {
        let slot = (time / length).rounded(.down)
        let into = time - slot * length
        let now = level(pattern(slot: slot), bulb: bulb, of: count, colors: colors, at: time)
        guard into > length - blend else { return now }
        let next = level(pattern(slot: slot + 1), bulb: bulb, of: count, colors: colors, at: time)
        return now + (next - now) * smoothstep(length - blend, length, into)
    }

    private static func pattern(slot: Double) -> Pattern {
        let all = Pattern.allCases
        let index = Int(slot.truncatingRemainder(dividingBy: Double(all.count)))
        return all[(index + all.count) % all.count]
    }

    /// A bulb's dimmest isn't quite dark: the glass still shows its color.
    private static let low = 0.08

    private static func level(_ pattern: Pattern, bulb: Int, of count: Int, colors: Int, at time: TimeInterval) -> Double {
        let color = Double(bulb % max(1, colors))
        let colors = Double(max(1, colors))
        switch pattern {
        case .twinkle:
            // Each bulb goes out for a second or so every 5 to 9 seconds, on its own clock.
            let beat = cycle(time / (5 + 4 * EventSchedule.unit(bulb, salt: 71)) + EventSchedule.unit(bulb, salt: 72))
            let out = beat < 0.16 ? pow(sin(.pi * beat / 0.16), 2) : 0
            return 0.95 - (0.95 - low) * out
        case .chase:
            let phase = cycle(time / 2.4 - color / colors)
            return low + (1 - low) * smoothstep(0, 0.2, phase) * (1 - smoothstep(0.42, 0.62, phase))
        case .slowFade:
            let swell = 0.5 - 0.5 * cos(2 * .pi * time / 6 + (bulb.isMultiple(of: 2) ? 0 : .pi))
            return low + (1 - low) * swell
        case .waves:
            let along = (Double(bulb) + 0.5) / Double(max(1, count))
            let crest = 0.5 + 0.5 * sin(2 * .pi * (time / 4 - along * 1.3))
            return low + (1 - low) * crest * crest
        case .colorByColor:
            // Over 8 seconds: red, green, gold and blue come on a half second apart, hold, then all go out.
            let phase = cycle(time / 8)
            let on = 0.04 + 0.52 * color / colors
            return low + (1 - low) * smoothstep(on, on + 0.07, phase) * (1 - smoothstep(0.76, 0.94, phase))
        }
    }
}

/// The candle in the jack-o'-lantern: it swells brighter and sinks dimmer every second or so, flutters a
/// little on top of that, and once in a while a draft nearly puts it out.
enum Candle {
    /// The flame at `time`, from 0 (embers) to 1 (blazing).
    static func flame(at time: TimeInterval, seed: Int = 0) -> Double {
        let swell = noise(time * 1.1, seed: seed)
        let flutter = noise(time * 5, seed: seed &+ 1) - 0.5
        // A slow wander that only matters near its peaks, which come about every half minute.
        let draft = smoothstep(0.82, 0.95, noise(time * 0.15, seed: seed &+ 2))
        return min(1, max(0, 0.3 + 0.62 * swell + 0.2 * flutter - 0.45 * draft))
    }

    /// Smooth random wandering in 0...1: a random height at each whole number of `x`, eased between them.
    static func noise(_ x: Double, seed: Int) -> Double {
        let whole = x.rounded(.down)
        let knot = Int(whole)
        let a = EventSchedule.unit(knot, salt: seed)
        let b = EventSchedule.unit(knot &+ 1, salt: seed)
        return a + (b - a) * smoothstep(0, 1, x - whole)
    }
}

/// 0 at or below `edge0`, 1 at or above `edge1`, and an S-curve between.
func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// The fractional part, for things that go round.
func cycle(_ value: Double) -> Double { value - value.rounded(.down) }
