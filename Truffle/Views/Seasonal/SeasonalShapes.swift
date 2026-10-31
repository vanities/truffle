import SwiftUI

/// The vector figures the seasonal backdrop draws: built once, at unit size around the origin, and
/// placed each frame with a transform.
enum SeasonalShapes {
    // MARK: - Snowflakes

    /// Six-fold flakes of radius 1: one arm, drawn once and turned six times.
    static let snowflakes: [Path] = [
        flake(arm: fernArm),
        flake(arm: plateArm, core: 0.24),
        flake(arm: sectorArm),
        flake(arm: crystalArm, core: 0.15),
    ]

    /// Stroke width for a flake drawn at `radius` points: never thinner than about half a point on screen.
    static func flakeStroke(radius: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: max(0.085, 0.55 / radius), lineCap: .round, lineJoin: .round)
    }

    // Arms run up from the center (0, 0) to the tip (0, -1).

    private static var fernArm: Path {
        var arm = Path()
        arm.move(to: .zero)
        arm.addLine(to: CGPoint(x: 0, y: -1))
        branch(&arm, at: 0.28, length: 0.34)
        branch(&arm, at: 0.5, length: 0.3)
        branch(&arm, at: 0.7, length: 0.21)
        branch(&arm, at: 0.86, length: 0.11)
        return arm
    }

    private static var plateArm: Path {
        var arm = Path()
        arm.move(to: CGPoint(x: 0, y: -0.24))
        arm.addLine(to: CGPoint(x: 0, y: -1))
        branch(&arm, at: 0.5, length: 0.2)
        // A little hexagonal plate near the tip.
        arm.addPath(hexagon(radius: 0.11).offsetBy(dx: 0, dy: -0.8))
        return arm
    }

    private static var sectorArm: Path {
        var arm = Path()
        arm.move(to: .zero)
        arm.addLine(to: CGPoint(x: 0, y: -1))
        // Sector plates: a kite on each side of the arm.
        for side: CGFloat in [-1, 1] {
            arm.move(to: CGPoint(x: 0, y: -0.24))
            arm.addLine(to: CGPoint(x: side * 0.22, y: -0.5))
            arm.addLine(to: CGPoint(x: 0, y: -0.68))
        }
        branch(&arm, at: 0.82, length: 0.15)
        return arm
    }

    private static var crystalArm: Path {
        var arm = Path()
        arm.move(to: CGPoint(x: 0, y: -0.15))
        arm.addLine(to: CGPoint(x: 0, y: -1))
        branch(&arm, at: 0.38, length: 0.13, angle: .pi / 2.4)
        branch(&arm, at: 0.62, length: 0.32)
        // The long branches grow a twig each, parallel to the arm.
        let tip = CGPoint(x: sin(.pi / 3) * 0.2, y: -0.62 - cos(.pi / 3) * 0.2)
        for side: CGFloat in [-1, 1] {
            arm.move(to: CGPoint(x: side * tip.x, y: tip.y))
            arm.addLine(to: CGPoint(x: side * tip.x, y: tip.y - 0.12))
        }
        return arm
    }

    /// A pair of side branches leaving the arm at `angle` from it, pointing outward.
    private static func branch(_ path: inout Path, at distance: CGFloat, length: CGFloat, angle: CGFloat = .pi / 3) {
        for side: CGFloat in [-1, 1] {
            path.move(to: CGPoint(x: 0, y: -distance))
            path.addLine(to: CGPoint(x: side * sin(angle) * length, y: -distance - cos(angle) * length))
        }
    }

    private static func flake(arm: Path, core: CGFloat? = nil) -> Path {
        var flake = Path()
        for turn in 0..<6 {
            flake.addPath(arm, transform: CGAffineTransform(rotationAngle: CGFloat(turn) * .pi / 3))
        }
        if let core { flake.addPath(hexagon(radius: core)) }
        return flake
    }

    /// Corners on the arms' angles, so arms meet it at a corner.
    private static func hexagon(radius: CGFloat) -> Path {
        var path = Path()
        for corner in 0..<6 {
            let angle = CGFloat(corner) * .pi / 3 - .pi / 2
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Sky

    /// A four-point twinkle of radius 1.
    static let sparkle: Path = {
        var path = Path()
        let waist: CGFloat = 0.2
        path.move(to: CGPoint(x: 0, y: -1))
        path.addQuadCurve(to: CGPoint(x: 1, y: 0), control: CGPoint(x: waist, y: -waist))
        path.addQuadCurve(to: CGPoint(x: 0, y: 1), control: CGPoint(x: waist, y: waist))
        path.addQuadCurve(to: CGPoint(x: -1, y: 0), control: CGPoint(x: -waist, y: waist))
        path.addQuadCurve(to: CGPoint(x: 0, y: -1), control: CGPoint(x: -waist, y: -waist))
        path.closeSubpath()
        return path
    }()

    /// A five-point star of radius 1.
    static let star: Path = {
        var path = Path()
        for corner in 0..<10 {
            let radius: CGFloat = corner.isMultiple(of: 2) ? 1 : 0.42
            let angle = CGFloat(corner) * .pi / 5 - .pi / 2
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }()

    /// A crescent moon of radius 1, lit on its lower left.
    static let crescent: Path = {
        let disc = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
        let shadow = Path(ellipseIn: CGRect(x: -0.6, y: -1.25, width: 1.9, height: 1.9))
        return disc.subtracting(shadow)
    }()

    // MARK: - Hearts and shamrocks

    /// A heart about 2 wide, its tip at (0, 0.9) and its notch at (0, -0.5).
    static let heart: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0.9))
        path.addCurve(to: CGPoint(x: -1, y: -0.25), control1: CGPoint(x: -0.42, y: 0.56), control2: CGPoint(x: -1, y: 0.22))
        path.addCurve(to: CGPoint(x: 0, y: -0.5), control1: CGPoint(x: -1, y: -0.98), control2: CGPoint(x: -0.12, y: -1.02))
        path.addCurve(to: CGPoint(x: 1, y: -0.25), control1: CGPoint(x: 0.12, y: -1.02), control2: CGPoint(x: 1, y: -0.98))
        path.addCurve(to: CGPoint(x: 0, y: 0.9), control1: CGPoint(x: 1, y: 0.22), control2: CGPoint(x: 0.42, y: 0.56))
        path.closeSubpath()
        return path
    }()

    /// Three heart leaves around the origin and a curled stem, about radius 1.
    static let shamrock: Path = {
        var path = Path()
        // A leaf is a heart with its tip at the center and its lobes outward.
        let leaf = heart.applying(CGAffineTransform(translationX: 0, y: -0.47).scaledBy(x: 0.52, y: 0.52))
        for turn in 0..<3 {
            path.addPath(leaf, transform: CGAffineTransform(rotationAngle: CGFloat(turn) * 2 * .pi / 3))
        }
        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: 0.05))
        stem.addQuadCurve(to: CGPoint(x: 0.3, y: 0.98), control: CGPoint(x: 0.02, y: 0.7))
        path.addPath(stem.strokedPath(StrokeStyle(lineWidth: 0.11, lineCap: .round)))
        return path
    }()

    // MARK: - Butterflies

    /// The right wings (the left are mirrored), for a butterfly seen from above with its head toward -y.
    static let forewing: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0.04, y: -0.12))
        path.addCurve(to: CGPoint(x: 0.92, y: -0.82), control1: CGPoint(x: 0.22, y: -0.72), control2: CGPoint(x: 0.62, y: -0.98))
        path.addCurve(to: CGPoint(x: 0.05, y: 0.06), control1: CGPoint(x: 1.18, y: -0.42), control2: CGPoint(x: 0.62, y: 0.02))
        path.closeSubpath()
        return path
    }()

    static let hindwing: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0.05, y: 0.02))
        path.addCurve(to: CGPoint(x: 0.66, y: 0.6), control1: CGPoint(x: 0.6, y: -0.02), control2: CGPoint(x: 0.86, y: 0.32))
        path.addCurve(to: CGPoint(x: 0.04, y: 0.24), control1: CGPoint(x: 0.42, y: 0.86), control2: CGPoint(x: 0.1, y: 0.6))
        path.closeSubpath()
        return path
    }()

    /// A spot near each forewing's tip.
    static let wingSpot = Path(ellipseIn: CGRect(x: 0.56, y: -0.7, width: 0.18, height: 0.15))

    static let butterflyBody: Path = {
        var path = Path(roundedRect: CGRect(x: -0.055, y: -0.32, width: 0.11, height: 0.78), cornerRadius: 0.055)
        for side: CGFloat in [-1, 1] {
            var feeler = Path()
            feeler.move(to: CGPoint(x: side * 0.02, y: -0.3))
            feeler.addQuadCurve(to: CGPoint(x: side * 0.22, y: -0.62), control: CGPoint(x: side * 0.04, y: -0.56))
            path.addPath(feeler.strokedPath(StrokeStyle(lineWidth: 0.035, lineCap: .round)))
        }
        return path
    }()
}
