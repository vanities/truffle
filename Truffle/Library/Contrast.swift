import Foundation

/// WCAG contrast, for keeping the season's colors readable. The accents are bright mid-tones: Halloween's
/// orange is about 3:1 on a white page, where text wants 4.5:1.
extension RGB {
    init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    /// Relative luminance, from 0 (black) to 1 (white).
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// From 1 (the same) to 21 (black on white).
    func contrast(with other: RGB) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    func mixed(with other: RGB, by amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    /// The nearest shade that reaches `ratio` against every page in `pages`: deepened toward black on
    /// light pages, lifted toward white on dark ones. Already readable, it comes back as is.
    func readable(on pages: [RGB], ratio: Double) -> RGB {
        let lightPages = pages.map(\.luminance).reduce(0, +) / Double(max(1, pages.count)) > 0.5
        let end = lightPages ? RGB(0x000000) : RGB(0xFFFFFF)
        for step in 0...50 {
            let shade = mixed(with: end, by: Double(step) / 50)
            if pages.allSatisfy({ shade.contrast(with: $0) >= ratio }) { return shade }
        }
        return end
    }

    /// The season's accent as the app's tint: readable as text on iOS's light or dark pages, and more so
    /// with Increase Contrast.
    func tint(dark: Bool, increasedContrast: Bool) -> RGB {
        readable(on: dark ? Self.darkPages : Self.lightPages, ratio: increasedContrast ? 7 : 4.5)
    }

    /// White or black, whichever reads better on this color: the label of a button filled with it.
    var onColor: RGB {
        contrast(with: RGB(0xFFFFFF)) >= contrast(with: RGB(0x000000)) ? RGB(0xFFFFFF) : RGB(0x000000)
    }

    /// iOS's backgrounds that the accent shows on as text: system, grouped and the cards on them.
    static let lightPages = [RGB(0xFFFFFF), RGB(0xF2F2F7)]
    static let darkPages = [RGB(0x000000), RGB(0x1C1C1E), RGB(0x2C2C2E)]
}
