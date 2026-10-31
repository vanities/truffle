import SwiftUI

/// Which card something rests on.
enum PerchSpot: Equatable {
    case shuffleAll
    case mix(Int)
}

extension View {
    /// Little pumpkins sitting on the card's top edge in the fall, snow piled along it in winter. Applied
    /// inside the card's button, so they press with it; they take no taps and stay above the content.
    func seasonalPerch(_ theme: SeasonTheme, spot: PerchSpot, cornerRadius: CGFloat) -> some View {
        modifier(SeasonalPerch(theme: theme, spot: spot, cornerRadius: cornerRadius))
    }
}

private struct SeasonalPerch: ViewModifier {
    let theme: SeasonTheme
    let spot: PerchSpot
    let cornerRadius: CGFloat
    @Environment(AppSettings.self) private var settings

    private var seed: Int {
        switch spot {
        case .shuffleAll: 3
        case .mix(let index): 11 + index * 7
        }
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if settings.seasonalEffects, theme.decor.contains(.snowCaps) {
                    SnowCap(seed: seed, cornerRadius: cornerRadius, pile: spot == .shuffleAll ? 10 : 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if settings.seasonalEffects, theme.decor.contains(.pumpkins), let patch = PumpkinPatch(theme: theme, spot: spot) {
                    patch
                }
            }
    }
}

/// One or two pumpkins on the edge, the small one in front. Carved and candle-lit for Halloween.
private struct PumpkinPatch: View {
    struct Piece: Identifiable {
        let image: String
        let height: CGFloat
        var id: String { image }
        var glows: Bool { image == "Prop-jackOLantern" }
    }

    let pieces: [Piece]
    let inset: CGFloat
    /// How far the bottoms sink into the edge, as if resting on it.
    private let sink: CGFloat = 3

    init?(theme: SeasonTheme, spot: PerchSpot) {
        let halloween = theme.moment == .halloween
        switch spot {
        case .shuffleAll:
            pieces = [Piece(image: halloween ? "Prop-jackOLantern" : "Prop-pumpkin", height: 40), Piece(image: "Prop-gourd", height: 25)]
            inset = 40
        case .mix(1):
            pieces = [Piece(image: halloween ? "Prop-pumpkin" : "Prop-gourd", height: 26)]
            inset = 30
        default:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: -8) {
            ForEach(pieces) { piece in
                Image(piece.image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: piece.height)
                    .background {
                        if piece.glows {
                            RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.1).opacity(0.5), .clear], center: .center,
                                           startRadius: 4, endRadius: piece.height * 1.1)
                                .frame(width: piece.height * 2.2, height: piece.height * 2.2)
                        }
                    }
            }
        }
        .background(alignment: .bottom) {
            // Where they touch the card.
            Ellipse()
                .fill(.black.opacity(0.32))
                .frame(height: 5)
                .padding(.horizontal, 6)
                .blur(radius: 2)
                .offset(y: 1)
        }
        .padding(.trailing, inset)
        // The overlay lines up their tops with the card's; lift them so their bottoms rest on its edge.
        .offset(y: sink - (pieces.map(\.height).max() ?? 0))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Snow piled along a card's top edge: lumpy, deepest in the middle, creeping round the corners, with
/// a few drips over the edge.
private struct SnowCap: View {
    let seed: Int
    let cornerRadius: CGFloat
    /// The deepest the pile gets above the edge.
    let pile: CGFloat

    var body: some View {
        SnowCapShape(seed: seed, cornerRadius: cornerRadius, pile: pile)
            .fill(LinearGradient(colors: [.white, Color(red: 0.86, green: 0.92, blue: 0.99)], startPoint: .top, endPoint: .bottom))
            .shadow(color: Color(red: 0.08, green: 0.16, blue: 0.32).opacity(0.3), radius: 1.5, y: 1)
            .frame(height: pile + 9)
            .offset(y: -pile)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct SnowCapShape: Shape {
    let seed: Int
    let cornerRadius: CGFloat
    let pile: CGFloat

    func path(in rect: CGRect) -> Path {
        let edge = pile
        let width = rect.width
        let radius = min(cornerRadius, width / 2)
        let start = radius * 0.4, end = width - radius * 0.4
        guard end - start > 20 else { return Path() }
        let s = Double(seed)
        func unit(_ salt: Int) -> Double { EventSchedule.unit(seed, salt: salt) }

        // The card's outline: flat on top, rounding down at the corners.
        func cardTop(_ x: CGFloat) -> CGFloat {
            let into = x < radius ? radius - x : (x > width - radius ? x - (width - radius) : 0)
            return edge + radius - sqrt(max(0, radius * radius - into * into))
        }
        func depth(_ x: CGFloat) -> CGFloat {
            let along = Double((x - start) / (end - start))
            let envelope = pow(max(0, sin(.pi * along)), 0.4)
            let lumps = 0.76 + 0.15 * sin(Double(x) / 11 + s) + 0.09 * sin(Double(x) / 4.6 + s * 2.3)
            return pile * envelope * lumps
        }
        let drips = (0..<3).map { index in
            (x: start + (end - start) * (0.14 + 0.72 * unit(index * 3)), depth: 2.2 + 3 * unit(index * 3 + 1), width: 2.6 + 2 * unit(index * 3 + 2))
        }

        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        var x = start
        while x < end {
            top.append(CGPoint(x: x, y: cardTop(x) - depth(x)))
            let drip = drips.reduce(0) { $0 + $1.depth * exp(-pow((x - $1.x) / $1.width, 2)) }
            bottom.append(CGPoint(x: x, y: cardTop(x) + 1.2 + drip))
            x += 2.5
        }
        top.append(CGPoint(x: end, y: cardTop(end)))
        bottom.append(CGPoint(x: end, y: cardTop(end) + 1.2))

        var path = Path()
        path.move(to: CGPoint(x: start, y: cardTop(start) + 1.2))
        smooth(&path, through: top)
        smooth(&path, through: bottom.reversed())
        path.closeSubpath()
        return path
    }

    /// Curves through the midpoints, so the outline has no corners.
    private func smooth(_ path: inout Path, through points: [CGPoint]) {
        guard var previous = points.first else { return }
        path.addLine(to: previous)
        for point in points.dropFirst() {
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
            previous = point
        }
        path.addLine(to: previous)
    }
}
