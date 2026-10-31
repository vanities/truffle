import SwiftUI

/// The wind at one moment. Now and then a gust (`SeasonEvents.gust`) sweeps the leaves to the right, lifts
/// them, sends a few looping the loop, and leaves them where it blew them: `pushed` only ever climbs, so a
/// leaf never snaps back, and one blown off the right comes back in on the left.
struct Gust {
    /// Gusts so far, the one blowing counted by how far along it is.
    let pushed: Double
    /// How hard it's blowing right now, 0 to 1.
    let strength: Double
    /// How far along the gust blowing now is, 0 to 1 (0 when it's calm).
    let progress: Double

    init(at time: TimeInterval, still: Bool) {
        guard !still else {
            pushed = 0
            strength = 0
            progress = 0
            return
        }
        let schedule = SeasonEvents.gust
        pushed = schedule.runningCount(at: time) { smoothstep(0, 1, $0) }
        progress = schedule.occurrence(at: time)?.progress ?? 0
        strength = pow(sin(.pi * progress), 2)
    }

    /// Where the wind has taken particle `index`, `carry` (near ones carry farther) times as far as most.
    func blow(_ index: Int, carry: Double) -> (dx: Double, dy: Double, turn: Double) {
        var dx = pushed * carry * 170
        var dy = -strength * (14 + 22 * carry)
        if index.isMultiple(of: 3) {
            let loop = 2 * Double.pi * smoothstep(0.2, 0.8, progress)
            let radius = 16 * strength * carry
            dx += radius * sin(loop)
            dy -= radius * (1 - cos(loop))
        }
        return (dx, dy, pushed * carry * 3.5 * (index.isMultiple(of: 2) ? 1 : -1))
    }
}

extension SeasonScene {
    /// Back on screen from the other side, for something the wind carried off an edge. `margin` is at
    /// least its size, so it wraps while it's out of sight.
    func wrap(_ x: CGFloat, margin: CGFloat) -> CGFloat {
        let span = size.width + margin * 2
        return x - span * ((x + margin) / span).rounded(.down)
    }

    // MARK: - Wind

    /// While a gust blows, a few wisps of wind: thin lines that draw themselves across the sky, roll up
    /// into a curl, and blow away.
    func windWisps(in context: inout GraphicsContext) {
        guard !still, let gust = SeasonEvents.gust.occurrence(at: time) else { return }
        let wisps = isWide ? 4 : 3
        let tint = Color(red: 1, green: 0.96, blue: 0.88)
        for wisp in 0..<wisps {
            let seed = gust.index &* 8 &+ wisp
            let begin = 0.2 + Double(wisp) * 0.55 + 0.35 * EventSchedule.unit(seed, salt: 1)
            let life = (gust.elapsed - begin) / 2.5
            guard life > 0, life < 1 else { continue }
            let length = size.width * (0.38 + 0.2 * EventSchedule.unit(seed, salt: 2))
            let row = (Double(wisp) + 0.2 + 0.6 * EventSchedule.unit(seed, salt: 3)) / Double(wisps)
            let start = CGPoint(x: -10 + (size.width - length) * 0.8 * EventSchedule.unit(seed, salt: 4) + 36 * life,
                                y: skyTop + 14 + 170 * row)
            let shape = Self.wisp(from: start, length: length, curls: wisp != 1, wave: EventSchedule.unit(seed, salt: 5))
                .trimmedPath(from: smoothstep(0.32, 1, life), to: smoothstep(0, 0.6, life))
            let fade = smoothstep(0, 0.15, life) * (1 - smoothstep(0.8, 1, life))
            context.stroke(shape, with: .color(tint.opacity(0.16 * fade)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            context.stroke(shape, with: .color(tint.opacity(0.68 * fade)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
    }

    /// A wisp of wind: a long, gentle wave, rolling up at its end into a curl that turns back over itself.
    static func wisp(from start: CGPoint, length: CGFloat, curls: Bool, wave: Double) -> Path {
        var points = (0...40).map { step in
            let along = Double(step) / 40
            return CGPoint(x: start.x + length * along, y: start.y + 5 * sin(2 * .pi * (along * 1.1 + wave)) * (1 - 0.4 * along))
        }
        if curls, let end = points.last {
            let radius: CGFloat = 11
            let center = CGPoint(x: end.x, y: end.y - radius)
            for step in 1...30 {
                let around = Double(step) / 30
                let angle = Double.pi / 2 - 2 * .pi * 1.15 * around
                let r = radius * (1 - 0.55 * around)
                points.append(CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r))
            }
        }
        var path = Path()
        path.addLines(points)
        return path
    }

    // MARK: - Spring sun

    /// Sunlight slanting in from above the top right corner: a few soft shafts that sway and breathe, and
    /// pollen drifting up through the air, glinting as it crosses a beam.
    func sunbeams(in context: inout GraphicsContext) {
        let sun = CGPoint(x: size.width * (isWide ? 0.78 : 0.86), y: skyTop - 150)
        let reach = size.height * 1.15
        let warm = Color(red: 1, green: 0.95, blue: 0.8)
        var light = context
        light.blendMode = .plusLighter
        light.fill(circle(sun, 300), with: .radialGradient(Gradient(colors: [warm.opacity(0.3), warm.opacity(0.08), warm.opacity(0)]),
                                                           center: sun, startRadius: 40, endRadius: 300))
        let count = isWide ? 7 : 5
        var beams: [(angle: Double, width: Double, glow: Double)] = []
        for beam in 0..<count {
            let angle = 1.75 + 0.75 * Double(beam) / Double(count - 1) + 0.03 * sin(time * 0.09 + Double(beam) * 1.9)
            let width = 0.045 + 0.05 * random(beam, 61)
            let glow = 0.07 + 0.09 * smoothNoise(time * 0.12 + Double(beam) * 3.1, seed: 60 + beam)
            beams.append((angle, width, glow))
            // A soft wide shaft with a brighter core down its middle.
            for (scale, share) in [(1.0, 0.55), (0.42, 1.0)] {
                let half = width * scale / 2
                var shaft = Path()
                shaft.move(to: sun)
                shaft.addLine(to: CGPoint(x: sun.x + cos(angle - half) * reach, y: sun.y + sin(angle - half) * reach))
                shaft.addLine(to: CGPoint(x: sun.x + cos(angle + half) * reach, y: sun.y + sin(angle + half) * reach))
                shaft.closeSubpath()
                light.fill(shaft, with: .radialGradient(Gradient(colors: [warm.opacity(glow * share), warm.opacity(glow * share * 0.4), warm.opacity(0)]),
                                                        center: sun, startRadius: 120, endRadius: reach))
            }
        }
        let gold = Color(red: 1, green: 0.93, blue: 0.62)
        for mote in 0..<(isWide ? 26 : 16) {
            let rise = cycle(time * (0.012 + 0.01 * random(mote, 71)) + random(mote, 72))
            let point = CGPoint(x: random(mote, 73) * size.width + 40 * rise + sin(time * (0.3 + 0.3 * random(mote, 74)) + random(mote, 75) * 6.28) * 18,
                                y: skyTop + 380 - 430 * rise)
            let bearing = atan2(point.y - sun.y, point.x - sun.x)
            let inBeam = beams.map { exp(-pow((bearing - $0.angle) / ($0.width * 0.6), 2)) * $0.glow * 6 }.max() ?? 0
            let alpha = (0.16 + min(0.7, inBeam)) * min(1, rise * 8) * min(1, (1 - rise) * 8)
            light.fill(circle(point, 0.9 + 1.2 * random(mote, 76)), with: .color(gold.opacity(alpha)))
        }
    }

    // MARK: - Winter night

    /// Northern lights: two curtains rippling across the top of the sky, green at the hem, fading up through
    /// teal to violet, with brighter rays drifting along them.
    func aurora(in context: inout GraphicsContext) {
        var sky = context
        sky.blendMode = .plusLighter
        let green = Color(red: 0.32, green: 1, blue: 0.6)
        let teal = Color(red: 0.25, green: 0.8, blue: 0.95)
        let violet = Color(red: 0.6, green: 0.42, blue: 1)
        let step: CGFloat = isWide ? 12 : 9
        for curtain in 0..<2 {
            let offset = Double(curtain)
            let base = skyTop + (isWide ? 70 : 58) + CGFloat(curtain) * 26
            let tall: CGFloat = (isWide ? 120 : 92) - CGFloat(curtain) * 28
            let swell = 0.7 + 0.3 * smoothNoise(time * 0.08 + offset * 9, seed: 90 + curtain)
            func hem(_ x: CGFloat) -> CGFloat {
                base + 16 * sin(Double(x) / 83 + time * 0.21 + offset * 2.2) + 7 * sin(Double(x) / 29 - time * 0.33 + offset)
            }
            func ray(_ x: CGFloat) -> Double { smoothNoise(Double(x) / 38 + time * 0.22 + offset * 40, seed: 80 + curtain) }
            var x = -step
            while x < size.width + step {
                let left = hem(x), right = hem(x + step)
                let leftTop = left - tall * (0.55 + 0.45 * ray(x)), rightTop = right - tall * (0.55 + 0.45 * ray(x + step))
                var band = Path()
                band.move(to: CGPoint(x: x, y: left + 8))
                band.addLine(to: CGPoint(x: x + step, y: right + 8))
                band.addLine(to: CGPoint(x: x + step, y: rightTop))
                band.addLine(to: CGPoint(x: x, y: leftTop))
                band.closeSubpath()
                let middle = (left + right) / 2
                let height = middle - (leftTop + rightTop) / 2
                let strength = (curtain == 0 ? 0.36 : 0.24) * swell * (0.35 + 0.65 * ray(x + step / 2))
                sky.fill(band, with: .linearGradient(Gradient(stops: [
                    .init(color: green.opacity(0), location: 0),
                    .init(color: green.opacity(strength), location: 0.08),
                    .init(color: teal.opacity(strength * 0.6), location: 0.35),
                    .init(color: violet.opacity(strength * 0.35), location: 0.7),
                    .init(color: violet.opacity(0), location: 1),
                ]), startPoint: CGPoint(x: x, y: middle + 8), endPoint: CGPoint(x: x, y: middle - height)))
                x += step
            }
        }
    }

    // MARK: - Visitors

    /// A bat flitting across the sky now and then: in from the right, across the moon's face, a swoop down
    /// through the open sky, and away at the left.
    func bat(in context: inout GraphicsContext) {
        guard !still, let flight = SeasonEvents.bat.occurrence(at: time) else { return }
        let moon = Self.moonCenter(in: size, skyTop: skyTop)
        let along = flight.progress
        let x = size.width + 24 - (size.width + 48) * along
        // It crosses the moon about a fifth of the way along, then climbs into the open sky above the words,
        // zigzagging as bats do.
        let zigzag = along * 23 + Double(flight.index)
        let y = moon.y - 6 - 30 * smoothstep(0.22, 1, along) + 7 * sin(zigzag)
        let beat = sin(flight.elapsed * 2 * .pi * 4.2)
        var flier = context
        flier.translateBy(x: x, y: y + 2 * beat)
        flier.rotate(by: .radians(-0.12 * cos(zigzag)))
        flier.scaleBy(x: isWide ? 20 : 17, y: isWide ? 20 : 17)
        // Moonlight catches its top edge, so it shows against the dark sky as well as across the moon.
        let rim = Color(red: 1, green: 0.86, blue: 0.6).opacity(0.45)
        let ink = Color(red: 0.07, green: 0.03, blue: 0.09)
        for (color, lift) in [(rim, -0.07), (ink, 0)] {
            var figure = flier
            figure.translateBy(x: 0, y: lift)
            for side: CGFloat in [-1, 1] {
                var wing = figure
                wing.scaleBy(x: side * (0.86 + 0.14 * abs(beat)), y: 0.25 + 0.75 * beat)
                wing.fill(SeasonalShapes.batWing, with: .color(color))
            }
            figure.fill(SeasonalShapes.batBody, with: .color(color))
        }
    }

    /// Now and then a shooting star streaks across the top of the sky and burns out.
    func shootingStar(in context: inout GraphicsContext) {
        guard !still, let streak = SeasonEvents.shootingStar.occurrence(at: time) else { return }
        let key = streak.index
        let leftward = EventSchedule.unit(key, salt: 1) < 0.5
        let angle = (leftward ? Double.pi - 0.32 : 0.32) + (EventSchedule.unit(key, salt: 2) - 0.5) * 0.2
        let across = EventSchedule.unit(key, salt: 3)
        let start = CGPoint(x: size.width * (leftward ? 0.55 + 0.35 * across : 0.1 + 0.35 * across),
                            y: skyTop - 10 + 36 * EventSchedule.unit(key, salt: 4))
        let travel = (isWide ? 300 : 200) * (0.8 + 0.4 * EventSchedule.unit(key, salt: 5))
        let along = travel * (1 - pow(1 - streak.progress, 1.8))
        let head = CGPoint(x: start.x + cos(angle) * along, y: start.y + sin(angle) * along)
        let trail = (isWide ? 110 : 80) * sin(.pi * min(1, streak.progress * 1.15))
        let fade = smoothstep(0, 0.1, streak.progress) * (1 - smoothstep(0.65, 1, streak.progress))
        var sky = context
        sky.blendMode = .plusLighter
        if trail > 0.5 {
            let tail = CGPoint(x: head.x - cos(angle) * trail, y: head.y - sin(angle) * trail)
            var line = Path()
            line.move(to: tail)
            line.addLine(to: head)
            sky.stroke(line, with: .linearGradient(Gradient(colors: [.white.opacity(0), Color(red: 0.86, green: 0.93, blue: 1).opacity(0.85 * fade)]),
                                                   startPoint: tail, endPoint: head),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        sky.fill(circle(head, 7), with: .radialGradient(Gradient(colors: [.white.opacity(0.45 * fade), .white.opacity(0)]),
                                                        center: head, startRadius: 0, endRadius: 7))
        sky.fill(circle(head, 1.5), with: .color(.white.opacity(fade)))
    }
}
