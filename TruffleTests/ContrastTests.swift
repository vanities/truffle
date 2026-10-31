import UIKit
import XCTest
@testable import Truffle

final class ContrastTests: XCTestCase {
    private var themes: [SeasonTheme] {
        Season.allCases.map { SeasonCalendar.theme(season: $0) } + Moment.allCases.map { SeasonCalendar.theme(moment: $0, season: .fall) }
    }

    func testContrastMatchesWCAG() {
        XCTAssertEqual(RGB(0x000000).contrast(with: RGB(0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(RGB(0x767676).contrast(with: RGB(0xFFFFFF)), 4.54, accuracy: 0.01)
        XCTAssertEqual(RGB(0xF2711C).contrast(with: RGB(0xFFFFFF)), RGB(0xFFFFFF).contrast(with: RGB(0xF2711C)))
    }

    /// The app wears each season's accent as its tint: links, toggles, the heart, the selected tab.
    func testEverySeasonsTintReadsOnLightAndDarkPages() {
        for theme in themes {
            for (name, pages) in [("light", RGB.lightPages), ("dark", RGB.darkPages)] {
                for ratio in [4.5, 7] {
                    let tint = theme.accent.readable(on: pages, ratio: ratio)
                    for page in pages {
                        XCTAssertGreaterThanOrEqual(tint.contrast(with: page), ratio, "\(theme.id) in \(name) at \(ratio):1")
                    }
                    // Still the season's color, not plain black or white.
                    XCTAssertNotEqual(tint, RGB(0x000000), "\(theme.id) in \(name) at \(ratio):1")
                    XCTAssertNotEqual(tint, RGB(0xFFFFFF), "\(theme.id) in \(name) at \(ratio):1")
                }
            }
        }
    }

    /// Play and the other tint-filled buttons: white words on the light-mode tint, black on the dark one.
    func testWordsOnATintFilledButtonRead() {
        for theme in themes {
            for dark in [false, true] {
                for increased in [false, true] {
                    let tint = theme.accent.tint(dark: dark, increasedContrast: increased)
                    XCTAssertGreaterThanOrEqual(tint.onColor.contrast(with: tint), 4.5, "\(theme.id) dark: \(dark)")
                }
            }
            XCTAssertEqual(theme.accent.tint(dark: false, increasedContrast: false).onColor, RGB(0xFFFFFF), theme.id)
        }
    }

    func testAReadableColorComesBackAsIs() {
        let navy = RGB(0x1A2B5C)
        XCTAssertEqual(navy.readable(on: RGB.lightPages, ratio: 4.5), navy)
    }

    @MainActor func testTheTintResolvesPerAppearance() {
        let theme = SeasonCalendar.theme(moment: .halloween, season: .fall)
        let light = UIColor(theme.tintColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = UIColor(theme.tintColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertGreaterThanOrEqual(rgb(light).contrast(with: RGB(0xFFFFFF)), 4.5)
        XCTAssertGreaterThanOrEqual(rgb(dark).contrast(with: RGB(0x1C1C1E)), 4.5)
        let high = UIColor(theme.tintColor).resolvedColor(with: UITraitCollection { traits in
            traits.userInterfaceStyle = .light
            traits.accessibilityContrast = .high
        })
        XCTAssertGreaterThanOrEqual(rgb(high).contrast(with: RGB(0xFFFFFF)), 7)
    }

    private func rgb(_ color: UIColor) -> RGB {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(red: red, green: green, blue: blue)
    }
}
