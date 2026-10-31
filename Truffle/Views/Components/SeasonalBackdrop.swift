import SwiftUI

/// Falling leaves in fall, snow in winter, petals in spring, fireflies in summer, embers for
/// Halloween, string lights for the holidays, confetti for New Year, hearts for Valentine's.
///
/// Every particle's path is a function of time and its index, so nothing is stored or simulated:
/// one Canvas draw per frame, at 30 fps, paused under Reduce Motion or when effects are off.
struct SeasonalBackdrop: View {
    let theme: SeasonTheme
    var density: Double = 1
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let paused = reduceMotion || !settings.seasonalEffects
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            Canvas(rendersAsynchronously: true) { canvas, size in
                guard settings.seasonalEffects else { return }
                let time = paused ? 12.0 : context.date.timeIntervalSinceReferenceDate
                Particles(theme: theme, density: density).draw(in: &canvas, size: size, time: time)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct Particles {
    let theme: SeasonTheme
    let density: Double

    /// A stable pseudo-random number in 0..<1 for particle `index`, attribute `salt`.
    private func random(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 73_856_093 ^ salt &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x % 1_000_000) / 1_000_000
    }

    private func count(_ base: Int) -> Int { max(1, Int(Double(base) * density)) }

    func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        switch theme.particles {
        case .leaves:
            falling("leaf.fill", in: &context, size: size, time: time, count: count(16), scale: 14...26, speed: 0.035...0.07, sway: 28)
        case .snow:
            snow(in: &context, size: size, time: time, count: count(70))
        case .petals:
            falling("camera.macro", in: &context, size: size, time: time, count: count(14), scale: 10...18, speed: 0.03...0.06, sway: 36)
        case .fireflies:
            fireflies(in: &context, size: size, time: time, count: count(26))
        case .embers:
            embers(in: &context, size: size, time: time, count: count(34))
            falling("leaf.fill", in: &context, size: size, time: time, count: count(7), scale: 12...20, speed: 0.03...0.05, sway: 30)
        case .lights:
            snow(in: &context, size: size, time: time, count: count(50))
            stringLights(in: &context, size: size, time: time)
        case .confetti:
            confetti(in: &context, size: size, time: time, count: count(46))
        case .hearts:
            rising("heart.fill", in: &context, size: size, time: time, count: count(14))
        }
    }

    private func falling(_ symbol: String, in context: inout GraphicsContext, size: CGSize, time: Double, count: Int,
                         scale: ClosedRange<Double>, speed: ClosedRange<Double>, sway: Double) {
        let colors = Array(theme.colors.dropFirst())
        for index in 0..<count {
            let fall = speed.lowerBound + random(index, 1) * (speed.upperBound - speed.lowerBound)
            let progress = (time * fall + random(index, 2)).truncatingRemainder(dividingBy: 1)
            let y = -0.1 * size.height + progress * size.height * 1.2
            let x = random(index, 3) * size.width + sin(time * (0.6 + random(index, 4)) + random(index, 5) * 6.28) * sway
            let side = scale.lowerBound + random(index, 6) * (scale.upperBound - scale.lowerBound)
            var leaf = context
            leaf.translateBy(x: x, y: y)
            leaf.rotate(by: .radians(time * (random(index, 7) - 0.5) * 2.4 + random(index, 8) * 6.28))
            leaf.opacity = 0.55 + random(index, 9) * 0.4
            var image = leaf.resolve(Image(systemName: symbol))
            image.shading = .color(colors[index % colors.count])
            leaf.draw(image, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
        }
    }

    private func rising(_ symbol: String, in context: inout GraphicsContext, size: CGSize, time: Double, count: Int) {
        for index in 0..<count {
            let rise = 0.03 + random(index, 1) * 0.04
            let progress = (time * rise + random(index, 2)).truncatingRemainder(dividingBy: 1)
            let y = size.height * 1.1 - progress * size.height * 1.25
            let x = random(index, 3) * size.width + sin(time * 0.9 + random(index, 5) * 6.28) * 18
            let side = 10 + random(index, 6) * 14
            var heart = context
            heart.opacity = (1 - progress) * 0.85
            var image = heart.resolve(Image(systemName: symbol))
            image.shading = .color(index.isMultiple(of: 2) ? theme.accentColor : theme.colors[2])
            heart.draw(image, in: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
        }
    }

    private func snow(in context: inout GraphicsContext, size: CGSize, time: Double, count: Int) {
        for index in 0..<count {
            let depth = random(index, 1)
            let fall = 0.025 + depth * 0.05
            let progress = (time * fall + random(index, 2)).truncatingRemainder(dividingBy: 1)
            let y = -10 + progress * (size.height + 20)
            let x = random(index, 3) * size.width + sin(time * (0.4 + depth) + random(index, 4) * 6.28) * 14
            let radius = 1.2 + depth * 3.2
            context.opacity = 0.35 + depth * 0.55
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(.white))
        }
        context.opacity = 1
    }

    private func fireflies(in context: inout GraphicsContext, size: CGSize, time: Double, count: Int) {
        for index in 0..<count {
            let x = (random(index, 1) + sin(time * 0.11 * (1 + random(index, 2)) + random(index, 3) * 6.28) * 0.08) * size.width
            let y = (0.25 + random(index, 4) * 0.7 + cos(time * 0.13 * (1 + random(index, 5))) * 0.05) * size.height
            let pulse = 0.5 + 0.5 * sin(time * (1.2 + random(index, 6) * 2) + random(index, 7) * 6.28)
            let radius = 6 + random(index, 8) * 6
            let glow = Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.55).opacity(0.9 * pulse), .clear])
            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(glow, center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius))
        }
    }

    private func embers(in context: inout GraphicsContext, size: CGSize, time: Double, count: Int) {
        for index in 0..<count {
            let rise = 0.04 + random(index, 1) * 0.06
            let progress = (time * rise + random(index, 2)).truncatingRemainder(dividingBy: 1)
            let y = size.height * (1.05 - progress * 1.15)
            let x = random(index, 3) * size.width + sin(time * 1.3 + random(index, 4) * 6.28) * 10
            let flicker = 0.55 + 0.45 * sin(time * (3 + random(index, 5) * 4) + random(index, 6) * 6.28)
            let radius = 2 + random(index, 7) * 3.5
            let color = index.isMultiple(of: 3) ? theme.colors[1] : theme.accentColor
            let glow = Gradient(colors: [color.opacity(flicker * (1 - progress * 0.6)), .clear])
            context.fill(Path(ellipseIn: CGRect(x: x - radius * 2, y: y - radius * 2, width: radius * 4, height: radius * 4)),
                         with: .radialGradient(glow, center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius * 2))
        }
    }

    private func stringLights(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let bulbs = 14
        let sag = 22.0
        var wire = Path()
        wire.move(to: CGPoint(x: -10, y: 18))
        wire.addQuadCurve(to: CGPoint(x: size.width + 10, y: 18), control: CGPoint(x: size.width / 2, y: 18 + sag * 2))
        context.stroke(wire, with: .color(.black.opacity(0.35)), lineWidth: 1.2)
        let colors: [Color] = [Color(red: 0.95, green: 0.25, blue: 0.25), Color(red: 0.25, green: 0.85, blue: 0.4),
                               Color(red: 1, green: 0.82, blue: 0.3), Color(red: 0.35, green: 0.6, blue: 1)]
        for index in 0..<bulbs {
            let t = (Double(index) + 0.5) / Double(bulbs)
            let x = -10 + t * (size.width + 20)
            let y = 18 + 4 * sag * t * (1 - t) + 6
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(time * (1.5 + random(index, 1)) + random(index, 2) * 6.28))
            let color = colors[index % colors.count]
            let glow = Gradient(colors: [color.opacity(twinkle), color.opacity(0)])
            context.fill(Path(ellipseIn: CGRect(x: x - 14, y: y - 14, width: 28, height: 28)),
                         with: .radialGradient(glow, center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 14))
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 5, width: 7, height: 10)), with: .color(color.opacity(0.6 + twinkle * 0.4)))
        }
    }

    private func confetti(in context: inout GraphicsContext, size: CGSize, time: Double, count: Int) {
        let colors = theme.colors + [.white, theme.accentColor]
        for index in 0..<count {
            let fall = 0.05 + random(index, 1) * 0.07
            let progress = (time * fall + random(index, 2)).truncatingRemainder(dividingBy: 1)
            let y = -10 + progress * (size.height + 20)
            let x = random(index, 3) * size.width + sin(time * 2 + random(index, 4) * 6.28) * 12
            var piece = context
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .radians(time * (2 + random(index, 5) * 4)))
            piece.scaleBy(x: 1, y: abs(cos(time * 3 + random(index, 6) * 6.28)))
            piece.fill(Path(CGRect(x: -3, y: -5, width: 6, height: 10)), with: .color(colors[index % colors.count]))
        }
    }
}
