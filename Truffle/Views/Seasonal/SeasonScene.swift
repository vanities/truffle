import SwiftUI

/// One frame of the seasonal backdrop. Every particle's path is a function of time and its index, so
/// nothing is stored or simulated between frames, and a still frame (Reduce Motion) is just a time.
struct SeasonScene {
    let theme: SeasonTheme
    let density: Double
    /// Where the open sky starts, just under the status bar, in the canvas's coordinates.
    let skyTop: CGFloat
    let size: CGSize
    let time: TimeInterval
    /// Reduce Motion: a still frame, without the occasional events.
    let still: Bool

    private var isWide: Bool { size.width > 600 }

    func draw(in context: inout GraphicsContext) {
        // The far sky first, then the weather in front of it.
        if theme.decor.contains(.moon) { nightStars(in: &context) }
        if theme.decor.contains(.rainbow) { rainbow(in: &context) }
        if theme.decor.contains(.fireworks) { fireworks(in: &context) }
        if theme.decor.contains(.sleigh) { flyby(in: &context) }
        switch theme.particles {
        case .leaves:
            falling("leaf.fill", in: &context, count: count(16), scale: 14...26, speed: 0.035...0.07, sway: 28)
        case .snow:
            snow(in: &context, dots: count(48), flakes: count(20))
        case .petals:
            falling("camera.macro", in: &context, count: count(12), scale: 10...18, speed: 0.03...0.06, sway: 36)
        case .fireflies:
            fireflies(in: &context, count: count(22))
        case .embers:
            embers(in: &context, count: count(34))
            falling("leaf.fill", in: &context, count: count(7), scale: 12...20, speed: 0.03...0.05, sway: 30)
        case .lights:
            snow(in: &context, dots: count(36), flakes: count(8))
            stringLights(in: &context)
        case .confetti:
            confetti(in: &context, count: count(40))
        case .hearts:
            hearts(in: &context, count: count(15))
        case .shamrocks:
            shamrocks(in: &context, count: count(14))
        case .stars:
            starConfetti(in: &context, count: count(18))
        }
        if theme.decor.contains(.butterflies) { butterflies(in: &context) }
    }

    // MARK: - Helpers

    /// A stable pseudo-random number in 0..<1 for particle `index`, attribute `salt`.
    private func random(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000
    }

    /// Wider screens get more, so an iPad isn't sparse.
    private func count(_ base: Int) -> Int {
        let widthScale = min(1.8, max(1, size.width / 440))
        return max(1, Int(Double(base) * density * widthScale))
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: - Falling and rising

    private func falling(_ symbol: String, in context: inout GraphicsContext, count: Int,
                         scale: ClosedRange<Double>, speed: ClosedRange<Double>, sway: Double) {
        // Resolved once per color, not once per particle.
        let images = theme.colors.dropFirst().map { color in
            var image = context.resolve(Image(systemName: symbol))
            image.shading = .color(color)
            return image
        }
        for index in 0..<count {
            let fall = speed.lowerBound + random(index, 1) * (speed.upperBound - speed.lowerBound)
            let progress = cycle(time * fall + random(index, 2))
            let y = -0.1 * size.height + progress * size.height * 1.2
            let x = random(index, 3) * size.width + sin(time * (0.6 + random(index, 4)) + random(index, 5) * 6.28) * sway
            let side = scale.lowerBound + random(index, 6) * (scale.upperBound - scale.lowerBound)
            var leaf = context
            leaf.translateBy(x: x, y: y)
            leaf.rotate(by: .radians(time * (random(index, 7) - 0.5) * 2.4 + random(index, 8) * 6.28))
            leaf.opacity = 0.55 + random(index, 9) * 0.4
            leaf.draw(images[index % images.count], in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        }
    }

    /// Hearts floating up, near ones bigger, brighter and glossier than far ones.
    private func hearts(in context: inout GraphicsContext, count: Int) {
        let colors = [theme.accentColor, theme.colors[2], Color(red: 1, green: 0.78, blue: 0.84)]
        for index in 0..<count {
            let depth = random(index, 1)
            let progress = cycle(time * (0.016 + depth * 0.026) + random(index, 2))
            let y = size.height * 1.05 - progress * size.height * 1.2
            let x = random(index, 3) * size.width + sin(time * (0.45 + depth * 0.4) + random(index, 5) * 6.28) * (10 + depth * 16)
            let radius = (5 + depth * 10) * (1 + 0.06 * sin(time * 2.6 + random(index, 7) * 6.28))
            let color = colors[index % colors.count]
            var heart = context
            heart.translateBy(x: x, y: y)
            heart.rotate(by: .radians(sin(time * 1.1 + random(index, 6) * 6.28) * 0.22))
            heart.scaleBy(x: radius, y: radius)
            // Fade in from the bottom and out near the top.
            heart.opacity = (0.35 + depth * 0.6) * min(1, progress * 6) * min(1, (1 - progress) * 3)
            if depth > 0.6 {
                heart.fill(circle(.zero, 1.9), with: .radialGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                                                                     center: .zero, startRadius: 0, endRadius: 1.9))
            }
            heart.fill(SeasonalShapes.heart, with: .linearGradient(Gradient(colors: [color.mix(with: .white, by: 0.35), color]),
                                                                  startPoint: CGPoint(x: 0, y: -1), endPoint: CGPoint(x: 0, y: 0.9)))
            heart.fill(Path(ellipseIn: CGRect(x: -0.72, y: -0.72, width: 0.42, height: 0.26)), with: .color(.white.opacity(0.5)))
        }
    }

    private func shamrocks(in context: inout GraphicsContext, count: Int) {
        let greens = [RGB(0x5FD98A), RGB(0x3EC46E), RGB(0xA8EC9C), RGB(0x7BE08F)].map(\.color)
        for index in 0..<count {
            let depth = random(index, 1)
            let progress = cycle(time * (0.02 + depth * 0.035) + random(index, 2))
            let y = -0.08 * size.height + progress * size.height * 1.16
            let x = random(index, 3) * size.width + sin(time * (0.45 + random(index, 4) * 0.5) + random(index, 5) * 6.28) * (16 + depth * 16)
            let radius = 5 + depth * 8
            // Turning over as it drifts: the width breathes like a leaf seen edge-on.
            let turn = 0.3 + 0.7 * abs(cos(time * (0.5 + random(index, 9) * 0.6) + random(index, 10) * 6.28))
            var leaf = context
            leaf.translateBy(x: x, y: y)
            leaf.rotate(by: .radians(time * (random(index, 7) - 0.5) * 1.4 + random(index, 8) * 6.28))
            leaf.scaleBy(x: radius * turn, y: radius)
            leaf.opacity = 0.55 + depth * 0.43
            leaf.fill(SeasonalShapes.shamrock, with: .linearGradient(Gradient(colors: [greens[index % greens.count].mix(with: .white, by: 0.25),
                                                                                       greens[index % greens.count]]),
                                                                     startPoint: CGPoint(x: 0, y: -1), endPoint: CGPoint(x: 0, y: 0.6)))
        }
        // A little luck in the air: gold glints.
        let gold = Color(red: 1, green: 0.84, blue: 0.38)
        for index in 0..<max(2, count / 3) {
            let x = random(index, 81) * size.width
            let y = cycle(random(index, 82) - time * 0.012) * size.height
            let twinkle = still ? 0.7 : max(0, sin(time * (1.4 + random(index, 83)) + random(index, 84) * 6.28))
            var glint = context
            glint.translateBy(x: x, y: y)
            glint.scaleBy(x: 3.2, y: 3.2)
            glint.opacity = 0.85 * twinkle
            glint.fill(SeasonalShapes.sparkle, with: .color(gold))
        }
    }

    /// Red, white and blue stars tumbling down, twinkling.
    private func starConfetti(in context: inout GraphicsContext, count: Int) {
        let colors: [Color] = [.white, Color(red: 1, green: 0.32, blue: 0.38), .white, Color(red: 0.5, green: 0.68, blue: 1)]
        for index in 0..<count {
            let depth = random(index, 1)
            let progress = cycle(time * (0.018 + depth * 0.03) + random(index, 2))
            let y = -12 + progress * (size.height + 24)
            let x = random(index, 3) * size.width + sin(time * (0.5 + random(index, 4)) + random(index, 5) * 6.28) * 14
            let radius = 3.6 + depth * 5
            let twinkle = still ? 1 : 0.65 + 0.35 * sin(time * (2 + random(index, 6) * 3) + random(index, 7) * 6.28)
            let color = colors[index % colors.count]
            var star = context
            star.translateBy(x: x, y: y)
            if depth > 0.55 {
                star.fill(circle(.zero, radius * 1.8), with: .radialGradient(Gradient(colors: [color.opacity(0.3 * twinkle), color.opacity(0)]),
                                                                           center: .zero, startRadius: 0, endRadius: radius * 1.8))
            }
            star.rotate(by: .radians(time * (random(index, 8) - 0.5) * 1.6 + random(index, 9) * 6.28))
            star.scaleBy(x: radius * (0.35 + 0.65 * abs(cos(time * (0.7 + random(index, 10)) + random(index, 11) * 6.28))), y: radius)
            star.opacity = (0.6 + depth * 0.38) * twinkle
            star.fill(SeasonalShapes.star, with: .color(color))
        }
    }

    // MARK: - Snow

    /// Far snow as small soft dots; nearer, detailed six-fold flakes that are bigger, faster, brighter
    /// and turn slowly.
    private func snow(in context: inout GraphicsContext, dots: Int, flakes: Int) {
        for index in 0..<dots {
            let depth = random(index, 1)
            let progress = cycle(time * (0.016 + depth * 0.028) + random(index, 2))
            let y = -10 + progress * (size.height + 20)
            let x = random(index, 3) * size.width + sin(time * (0.3 + depth * 0.6) + random(index, 4) * 6.28) * (6 + depth * 8)
            context.opacity = 0.22 + depth * 0.45
            context.fill(circle(CGPoint(x: x, y: y), 0.8 + depth * 1.7), with: .color(.white))
        }
        context.opacity = 1
        for index in 0..<flakes {
            let depth = 0.3 + 0.7 * random(index, 21)
            let radius = 3 + depth * depth * 10
            let progress = cycle(time * (0.018 + depth * 0.042) + random(index, 22))
            let y = -radius + progress * (size.height + radius * 2)
            let x = random(index, 23) * size.width + sin(time * (0.25 + depth * 0.45) + random(index, 24) * 6.28) * (8 + depth * 18)
            let spin = time * (0.1 + random(index, 25) * 0.3) * (index.isMultiple(of: 2) ? 1 : -1) + random(index, 26) * 6.28
            var flake = context
            flake.translateBy(x: x, y: y)
            flake.rotate(by: .radians(spin))
            flake.scaleBy(x: radius, y: radius)
            flake.opacity = 0.28 + depth * 0.64
            if depth > 0.78 {
                flake.fill(circle(.zero, 1.3), with: .radialGradient(Gradient(colors: [.white.opacity(0.24), .white.opacity(0)]),
                                                                  center: .zero, startRadius: 0, endRadius: 1.3))
            }
            flake.stroke(SeasonalShapes.snowflakes[index % SeasonalShapes.snowflakes.count], with: .color(.white),
                         style: SeasonalShapes.flakeStroke(radius: radius))
        }
    }

    // MARK: - Glows

    /// Soft halos that breathe, with now and then a bright blink.
    private func fireflies(in context: inout GraphicsContext, count: Int) {
        var night = context
        night.blendMode = .plusLighter
        let lime = Color(red: 0.86, green: 1, blue: 0.42)
        let amber = Color(red: 1, green: 0.84, blue: 0.4)
        for index in 0..<count {
            let x = (random(index, 1) + sin(time * 0.11 * (1 + random(index, 2)) + random(index, 3) * 6.28) * 0.08) * size.width
            let y = (0.25 + random(index, 4) * 0.7 + cos(time * 0.13 * (1 + random(index, 5))) * 0.05) * size.height
            let breathe = 0.5 + 0.5 * sin(time * (0.7 + random(index, 6)) + random(index, 7) * 6.28)
            let beat = cycle(time * (0.14 + random(index, 9) * 0.18) + random(index, 10))
            let blink = beat < 0.12 ? sin(.pi * beat / 0.12) : 0
            let glow = still ? 0.75 : min(1, 0.4 + 0.35 * breathe + 0.5 * blink)
            let halo = 18 + random(index, 8) * 14
            let tint = index % 4 == 0 ? amber : lime
            let center = CGPoint(x: x, y: y)
            night.fill(circle(center, halo), with: .radialGradient(
                Gradient(stops: [.init(color: tint.opacity(glow), location: 0), .init(color: tint.opacity(0.55 * glow), location: 0.25),
                                 .init(color: tint.opacity(0.18 * glow), location: 0.55), .init(color: tint.opacity(0), location: 1)]),
                center: center, startRadius: 0, endRadius: halo))
            night.fill(circle(center, 2 + random(index, 11)), with: .color(Color(red: 1, green: 1, blue: 0.9).opacity(0.55 + 0.45 * glow)))
        }
    }

    private func embers(in context: inout GraphicsContext, count: Int) {
        for index in 0..<count {
            let rise = 0.04 + random(index, 1) * 0.06
            let progress = cycle(time * rise + random(index, 2))
            let y = size.height * (1.05 - progress * 1.15)
            let x = random(index, 3) * size.width + sin(time * 1.3 + random(index, 4) * 6.28) * 10
            let flicker = 0.55 + 0.45 * sin(time * (3 + random(index, 5) * 4) + random(index, 6) * 6.28)
            let radius = 2 + random(index, 7) * 3.5
            let color = index.isMultiple(of: 3) ? theme.colors[1] : theme.accentColor
            let glow = Gradient(colors: [color.opacity(flicker * (1 - progress * 0.6)), .clear])
            context.fill(circle(CGPoint(x: x, y: y), radius * 2),
                         with: .radialGradient(glow, center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius * 2))
        }
    }

    /// A string of bulbs hung just under the status bar (two swags on a wide screen), run like a light
    /// controller (`LightShow`): cold colored glass when off; lit, a hot core and a halo.
    private func stringLights(in context: inout GraphicsContext) {
        let swags = isWide ? 2 : 1
        let swagWidth = (size.width + 20) / CGFloat(swags)
        let top = skyTop + 2
        let sag: CGFloat = 15
        let bulbs = max(9, Int(swagWidth / 30))
        let colors: [Color] = [Color(red: 0.95, green: 0.25, blue: 0.25), Color(red: 0.25, green: 0.85, blue: 0.4),
                               Color(red: 1, green: 0.82, blue: 0.3), Color(red: 0.35, green: 0.6, blue: 1)]
        var halos = context
        halos.blendMode = .plusLighter
        for swag in 0..<swags {
            let left = -10 + CGFloat(swag) * swagWidth
            var wire = Path()
            wire.move(to: CGPoint(x: left, y: top))
            wire.addQuadCurve(to: CGPoint(x: left + swagWidth, y: top), control: CGPoint(x: left + swagWidth / 2, y: top + sag * 2))
            context.stroke(wire, with: .color(.black.opacity(0.4)), lineWidth: 1.2)
            for bulb in 0..<bulbs {
                // One controller runs every swag, so on a wide screen the chase carries on into the next.
                let index = swag * bulbs + bulb
                let t = (Double(bulb) + 0.5) / Double(bulbs)
                let x = left + t * swagWidth
                let y = top + 4 * sag * t * (1 - t) + 7
                let lit = still ? 0.9 : LightShow.level(bulb: index, of: swags * bulbs, colors: colors.count, at: time)
                let color = colors[index % colors.count]
                let center = CGPoint(x: x, y: y)
                halos.fill(circle(center, 15), with: .radialGradient(Gradient(colors: [color.opacity(0.7 * lit), color.opacity(0)]),
                                                                     center: center, startRadius: 0, endRadius: 15))
                context.fill(Path(roundedRect: CGRect(x: x - 2, y: y - 8.5, width: 4, height: 4), cornerRadius: 1), with: .color(.black.opacity(0.55)))
                var glass = context
                glass.translateBy(x: x, y: y)
                glass.scaleBy(x: 7, y: 10)
                glass.fill(SeasonalShapes.bulb, with: .color(color.mix(with: .black, by: 0.5 * (1 - lit)).mix(with: .white, by: 0.22 * lit)))
                glass.fill(SeasonalShapes.bulbCore, with: .color(.white.opacity(0.6 * lit)))
                glass.fill(SeasonalShapes.bulbShine, with: .color(.white.opacity(0.22 + 0.2 * lit)))
            }
        }
    }

    private func confetti(in context: inout GraphicsContext, count: Int) {
        let colors = theme.colors + [.white, theme.accentColor]
        for index in 0..<count {
            let fall = 0.05 + random(index, 1) * 0.07
            let progress = cycle(time * fall + random(index, 2))
            let y = -10 + progress * (size.height + 20)
            let x = random(index, 3) * size.width + sin(time * 2 + random(index, 4) * 6.28) * 12
            var piece = context
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .radians(time * (2 + random(index, 5) * 4)))
            piece.scaleBy(x: 1, y: abs(cos(time * 3 + random(index, 6) * 6.28)))
            piece.fill(Path(CGRect(x: -3, y: -5, width: 6, height: 10)), with: .color(colors[index % colors.count]))
        }
    }

    // MARK: - Sky

    static func moonCenter(in size: CGSize, skyTop: CGFloat) -> CGPoint {
        size.width > 600 ? CGPoint(x: size.width - 120, y: skyTop + 50) : CGPoint(x: size.width - 62, y: skyTop + 42)
    }

    static func moonRadius(in size: CGSize) -> CGFloat { size.width > 600 ? 28 : 20 }

    /// A crescent with a soft halo and the dark side just showing (earthshine).
    static func drawMoon(in context: inout GraphicsContext, size: CGSize, skyTop: CGFloat) {
        let center = moonCenter(in: size, skyTop: skyTop)
        let radius = moonRadius(in: size)
        let light = Color(red: 1, green: 0.95, blue: 0.8)
        let halo = radius * 3.6
        context.fill(Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
                     with: .radialGradient(Gradient(stops: [.init(color: light.opacity(0.3), location: 0), .init(color: light.opacity(0.1), location: 0.38),
                                                            .init(color: light.opacity(0), location: 1)]),
                                           center: center, startRadius: radius * 0.5, endRadius: halo))
        var moon = context
        moon.translateBy(x: center.x, y: center.y)
        moon.scaleBy(x: radius, y: radius)
        moon.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)), with: .color(light.opacity(0.08)))
        moon.fill(SeasonalShapes.crescent, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.98, blue: 0.9), Color(red: 0.98, green: 0.83, blue: 0.55)]),
                                                                startPoint: CGPoint(x: -1, y: -0.3), endPoint: CGPoint(x: 0.6, y: 1)))
    }

    /// A few stars around the moon: above the header and to the right of it, never behind the words.
    private func nightStars(in context: inout GraphicsContext) {
        let moon = Self.moonCenter(in: size, skyTop: skyTop)
        let clearance = Self.moonRadius(in: size) * 2
        let warm = Color(red: 1, green: 0.96, blue: 0.86)
        var sky = context
        sky.blendMode = .plusLighter
        for index in 0..<(isWide ? 24 : 13) {
            let point = index % 3 == 2
                ? CGPoint(x: size.width - 14 - random(index, 51) * min(130, size.width * 0.3), y: skyTop + 40 + random(index, 52) * 130)
                : CGPoint(x: 10 + random(index, 53) * (size.width - 20), y: skyTop - 4 + random(index, 54) * 52)
            guard hypot(point.x - moon.x, point.y - moon.y) > clearance else { continue }
            let twinkle = still ? 0.85 : 0.5 + 0.5 * sin(time * (0.9 + random(index, 55) * 1.8) + random(index, 56) * 6.28)
            let radius = 0.9 + random(index, 57) * 1.4
            let alpha = (0.4 + random(index, 58) * 0.55) * (0.35 + 0.65 * twinkle)
            if radius > 1.7 {
                var star = sky
                star.translateBy(x: point.x, y: point.y)
                star.scaleBy(x: radius * 2.4, y: radius * 2.4)
                star.fill(SeasonalShapes.sparkle, with: .color(warm.opacity(alpha)))
            } else {
                sky.fill(circle(point, radius * 0.75), with: .color(warm.opacity(alpha)))
            }
        }
    }

    /// Santa's sleigh and reindeer across the sky, as a silhouette rimmed in moonlight, dropping a
    /// trail of sparkles that hang where they fell and fade. The path is fixed in the sky: level in the
    /// gap between the lights and the greeting, dipping into the open space right of it.
    private func flyby(in context: inout GraphicsContext) {
        let schedule = SeasonEvents.flyby
        guard !still, let flight = schedule.occurrence(at: time) else { return }
        var sleigh = context.resolve(Image("Prop-sleigh"))
        let width: CGFloat = isWide ? 160 : 128
        let height = width * sleigh.size.height / max(1, sleigh.size.width)
        let rightward = flight.index.isMultiple(of: 2)
        let span = size.width + width * 1.3
        let dip: CGFloat = isWide ? 40 : 34
        // Its bottom clears the label (64 pt down) where the words are.
        let level = skyTop + 62 - height / 2
        func altitude(_ x: CGFloat) -> CGFloat {
            level + dip * pow(min(1.2, max(0, x / size.width)), 3)
        }
        func point(_ progress: Double) -> CGPoint {
            let travel = -width * 0.65 + span * progress
            let x = rightward ? travel : size.width - travel
            return CGPoint(x: x, y: altitude(x))
        }

        let gold = Color(red: 1, green: 0.86, blue: 0.5)
        var trail = context
        trail.blendMode = .plusLighter
        let every = 0.04, life = 1.2
        let newest = Int(flight.elapsed / every)
        for drop in max(0, Int((flight.elapsed - life) / every))...newest {
            let dropped = Double(drop) * every
            let age = flight.elapsed - dropped
            guard age >= 0, age < life else { continue }
            var at = point(dropped / schedule.duration)
            at.x += (rightward ? -1 : 1) * width * 0.4 + (random(drop, 32) - 0.5) * 10
            at.y += height * 0.2 + age * age * 26 + (random(drop, 31) - 0.5) * 8
            let fade = 1 - age / life
            let radius = (1 + 2.2 * random(drop, 33)) * (0.4 + 0.6 * fade)
            var spark = trail
            spark.translateBy(x: at.x, y: at.y)
            spark.scaleBy(x: radius, y: radius)
            spark.opacity = fade * (0.55 + 0.45 * sin(time * 14 + Double(drop)))
            spark.fill(SeasonalShapes.sparkle, with: .color(drop % 3 == 0 ? .white : gold))
        }

        var here = point(flight.progress)
        here.y += sin(time * 3.4) * 1.5
        // Nose up when climbing, down when dipping, whichever way it flies (the flip comes after the turn).
        let climb = 3 * dip * pow(min(1.2, max(0, here.x / size.width)), 2) / size.width
        var figure = context
        figure.translateBy(x: here.x, y: here.y)
        figure.rotate(by: .radians(atan(climb) * 0.8))
        if !rightward { figure.scaleBy(x: -1, y: 1) }
        let frame = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        sleigh.shading = .color(gold.opacity(0.55))
        figure.draw(sleigh, in: frame.offsetBy(dx: 0, dy: -0.9))
        sleigh.shading = .color(Color(red: 0.05, green: 0.03, blue: 0.07).opacity(0.82))
        figure.draw(sleigh, in: frame)
    }

    /// A short show: a few shells climb and burst into streaks that slow, droop and glitter out, each
    /// with a soft haze of its color and crackling tips in a second one.
    private func fireworks(in context: inout GraphicsContext) {
        let fourth = theme.moment == .fourthOfJuly
        let schedule = fourth ? SeasonEvents.fourthFireworks : SeasonEvents.newYearFireworks
        guard !still, let show = schedule.occurrence(at: time) else { return }
        let palette: [Color] = fourth
            ? [Color(red: 1, green: 0.28, blue: 0.34), Color(red: 0.97, green: 0.97, blue: 1), Color(red: 0.4, green: 0.6, blue: 1)]
            : [Color(red: 1, green: 0.82, blue: 0.4), Color(red: 1, green: 0.96, blue: 0.86), Color(red: 1, green: 0.66, blue: 0.6)]
        var sky = context
        sky.blendMode = .plusLighter
        for burst in 0..<3 {
            let key = show.index &* 16 &+ burst
            let since = show.elapsed - (Double(burst) * 1.5 + EventSchedule.unit(key, salt: 1) * 0.6)
            guard since > 0 else { continue }
            let center = burstCenter(burst, key: key)
            let reach = (isWide ? 92 : 68) * (0.85 + 0.3 * EventSchedule.unit(key, salt: 4)) * (burst == 1 ? 0.7 : 1)
            let color = palette[(show.index + burst) % palette.count]
            let crackle = palette[(show.index + burst + 1) % palette.count]
            let climb = 0.55
            if since < climb {
                let eased = 1 - pow(1 - since / climb, 2)
                for spark in 0..<5 {
                    let back = Double(spark) * 0.035
                    let lag = 1 - pow(1 - max(0, since - back) / climb, 2)
                    let at = CGPoint(x: center.x - 10 * (1 - lag), y: center.y + 90 * (1 - lag))
                    sky.fill(circle(at, 1.7 - CGFloat(spark) * 0.28), with: .color(Color(red: 1, green: 0.85, blue: 0.6).opacity((1 - Double(spark) / 5) * eased)))
                }
                continue
            }
            let age = since - climb
            let life = 2.6
            guard age < life else { continue }
            let fade = pow(1 - age / life, 1.3)
            let spread = 1 - exp(-2.6 * age)
            // The flash, then a haze of the burst's color that spreads and fades with it.
            if age < 0.18 {
                sky.fill(circle(center, 20), with: .radialGradient(Gradient(colors: [Color.white.opacity(0.5 * (1 - age / 0.18)), color.opacity(0)]),
                                                                   center: center, startRadius: 0, endRadius: 20))
            }
            let haze = reach * (0.5 + 0.8 * spread)
            sky.fill(circle(center, haze), with: .radialGradient(Gradient(colors: [color.opacity(0.22 * fade), color.opacity(0)]),
                                                                 center: center, startRadius: 0, endRadius: haze))
            let sparks = 44
            // Each spark trails a tail that fades toward where it was: one gradient stroke per spark.
            let tail = min(age, 0.45)
            for spark in 0..<sparks {
                let seed = key &* 64 &+ spark
                let angle = Double(spark) / Double(sparks) * 2 * .pi + EventSchedule.unit(seed, salt: 5) * 0.14
                let distance = reach * (0.75 + 0.3 * EventSchedule.unit(seed, salt: 6))
                func at(_ t: Double) -> CGPoint {
                    let out = distance * (1 - exp(-2.6 * t))
                    return CGPoint(x: center.x + cos(angle) * out, y: center.y + sin(angle) * out + 16 * t * t)
                }
                let head = at(age)
                let end = at(age - tail)
                var streak = Path()
                streak.move(to: end)
                for step in 1...3 { streak.addLine(to: at(age - tail + tail * Double(step) / 3)) }
                sky.stroke(streak, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(fade)]), startPoint: end, endPoint: head),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                let glitter = age > life * 0.45 ? 0.3 + 0.7 * max(0, sin(time * 24 + Double(spark) * 2.1)) : 1
                sky.fill(circle(head, 1.6), with: .color(crackle.opacity(fade * glitter)))
            }
        }
    }

    /// Bursts go right of the greeting, or high over it, so the words stay clear.
    private func burstCenter(_ burst: Int, key: Int) -> CGPoint {
        let across = EventSchedule.unit(key, salt: 2)
        let down = EventSchedule.unit(key, salt: 3)
        if burst == 1 {
            return CGPoint(x: size.width * (0.2 + 0.55 * across), y: skyTop + 16 + 18 * down)
        }
        let x = isWide ? size.width * (0.58 + 0.34 * across) : size.width * (0.76 + 0.12 * across)
        return CGPoint(x: x, y: skyTop + 40 + 60 * down)
    }

    /// A rainbow that paints itself across the sky from behind the Shuffle All card, glints, and fades.
    private func rainbow(in context: inout GraphicsContext) {
        guard !still, let event = SeasonEvents.rainbow.occurrence(at: time) else { return }
        let grow = smoothstep(0, 0.45, event.progress)
        let alpha = 0.4 * smoothstep(0, 0.12, event.progress) * (1 - smoothstep(0.68, 1, event.progress))
        let radius = isWide ? min(size.width * 0.34, 360) : size.width * 0.6
        let center = CGPoint(x: size.width * (isWide ? 0.68 : 0.64), y: skyTop + 36 + radius)
        let start = Double.pi * 1.04
        let end = start + Double.pi * 0.9 * grow
        let bands = [RGB(0xFF5A5F), RGB(0xFFA54A), RGB(0xFFE066), RGB(0x6BD68A), RGB(0x5AA9FF), RGB(0xA77BFF)].map(\.color)
        let band: CGFloat = isWide ? 6 : 4.5
        var tip = CGPoint.zero
        for (ring, color) in bands.enumerated() {
            let r = radius - CGFloat(ring) * band
            var arc = Path()
            for step in 0...48 {
                let theta = start + (end - start) * Double(step) / 48
                let point = CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r)
                if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
                if ring == 2 { tip = point }
            }
            context.stroke(arc, with: .color(color.opacity(alpha)), lineWidth: band + 0.6)
        }
        // Once it's up, a shimmer runs along it: short pieces that brighten toward the middle.
        let sweep = smoothstep(0.42, 0.8, event.progress)
        if sweep > 0, sweep < 1 {
            var glow = context
            glow.blendMode = .plusLighter
            let middle = start + (end - start) * sweep
            let mid = radius - band * 2.5
            for piece in -5...5 {
                let theta = middle + Double(piece) * 0.035
                var shine = Path()
                shine.move(to: CGPoint(x: center.x + cos(theta - 0.018) * mid, y: center.y + sin(theta - 0.018) * mid))
                shine.addLine(to: CGPoint(x: center.x + cos(theta + 0.018) * mid, y: center.y + sin(theta + 0.018) * mid))
                let weight = 1 - Double(abs(piece)) / 6
                glow.stroke(shine, with: .color(.white.opacity(0.22 * weight * sin(.pi * sweep))), lineWidth: band * 6)
            }
        }
        if grow < 0.98 {
            var glint = context
            glint.blendMode = .plusLighter
            glint.translateBy(x: tip.x, y: tip.y)
            glint.scaleBy(x: 7, y: 7)
            glint.opacity = min(1, alpha * 3)
            glint.fill(SeasonalShapes.sparkle, with: .color(.white))
        }
    }

    /// A few butterflies wandering the header, flapping: over the words they keep to the sky above them,
    /// and only dip down in the open space to their right.
    private func butterflies(in context: inout GraphicsContext) {
        let wings: [(Color, Color)] = [
            (RGB(0xF59AC0).color, RGB(0xFFD2E2).color), (RGB(0xFFD45C).color, RGB(0xFFF0B0).color),
            (RGB(0xB9A1F7).color, RGB(0xE3D7FF).color), (RGB(0x86CCFF).color, RGB(0xD2ECFF).color),
            (RGB(0xFFFFFF).color, RGB(0xF3EFE6).color),
        ]
        for index in 0..<(isWide ? 5 : 3) {
            let phase = random(index, 41) * 2 * .pi
            let pace = 0.06 + random(index, 42) * 0.035
            let ax = 2.1 + random(index, 43), ay = 3.3 + random(index, 44)
            func position(_ time: Double) -> CGPoint {
                let t = time * pace
                let x = size.width * (0.5 + 0.43 * sin(t * ax + phase))
                let open = min(1, max(0, (x / size.width - 0.7) / 0.22))
                let y = skyTop + 30 + 22 * sin(t * ay + phase * 1.7) + open * 80 * (0.5 + 0.5 * sin(t * ay * 0.6 + phase))
                    + 6 * sin(time * 1.9 + phase)
                return CGPoint(x: x, y: y)
            }
            let here = position(time)
            let before = position(time - 0.1)
            let heading = atan2(here.y - before.y, here.x - before.x)
            let flap = still ? 0.85 : 0.2 + 0.8 * abs(cos(time * (7 + random(index, 45) * 2) + phase))
            let span = 12 + random(index, 46) * 5
            let (fore, hind) = wings[index % wings.count]
            var flier = context
            flier.translateBy(x: here.x, y: here.y)
            flier.rotate(by: .radians(heading + .pi / 2))
            flier.scaleBy(x: span, y: span)
            flier.opacity = 0.92
            for side: CGFloat in [-1, 1] {
                var wing = flier
                wing.scaleBy(x: side * flap, y: 1)
                wing.fill(SeasonalShapes.hindwing, with: .color(hind))
                wing.fill(SeasonalShapes.forewing, with: .color(fore))
                wing.fill(SeasonalShapes.wingSpot, with: .color(.white.opacity(0.75)))
            }
            flier.fill(SeasonalShapes.butterflyBody, with: .color(Color(red: 0.18, green: 0.12, blue: 0.14)))
        }
    }
}
