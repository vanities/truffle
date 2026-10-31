import UIKit
import XCTest
@testable import Truffle

final class SeasonsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testMeteorologicalSeasonsInBothHemispheres() {
        XCTAssertEqual(Season.of(month: 10, southern: false), .fall)
        XCTAssertEqual(Season.of(month: 1, southern: false), .winter)
        XCTAssertEqual(Season.of(month: 7, southern: false), .summer)
        XCTAssertEqual(Season.of(month: 4, southern: false), .spring)
        XCTAssertEqual(Season.of(month: 12, southern: true), .summer)
        XCTAssertEqual(Season.of(month: 4, southern: true), .fall)
        XCTAssertEqual(Season.fall.startMonth(southern: false), 9)
        XCTAssertEqual(Season.fall.startMonth(southern: true), 3)
        XCTAssertEqual(Season.winter.startMonth(southern: true), 6)
    }

    func testMoments() {
        XCTAssertEqual(SeasonCalendar.moment(for: date(2026, 10, 30), calendar: calendar), .halloween)
        XCTAssertNil(SeasonCalendar.moment(for: date(2026, 10, 14), calendar: calendar))
        XCTAssertNil(SeasonCalendar.moment(for: date(2026, 11, 1), calendar: calendar))
        // Thanksgiving 2026 is November 26: its week is the 20th through the 26th, and the holidays
        // start the day after.
        XCTAssertEqual(SeasonCalendar.thanksgiving(year: 2026, calendar: calendar), date(2026, 11, 26, hour: 0))
        XCTAssertNil(SeasonCalendar.moment(for: date(2026, 11, 19), calendar: calendar))
        XCTAssertEqual(SeasonCalendar.moment(for: date(2026, 11, 20), calendar: calendar), .thanksgiving)
        XCTAssertEqual(SeasonCalendar.moment(for: date(2026, 11, 26), calendar: calendar), .thanksgiving)
        XCTAssertEqual(SeasonCalendar.moment(for: date(2026, 11, 27), calendar: calendar), .christmas)
        XCTAssertEqual(SeasonCalendar.moment(for: date(2026, 12, 25), calendar: calendar), .christmas)
        XCTAssertEqual(SeasonCalendar.moment(for: date(2026, 12, 31), calendar: calendar), .newYear)
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 1, 1), calendar: calendar), .newYear)
        XCTAssertNil(SeasonCalendar.moment(for: date(2027, 1, 2), calendar: calendar))
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 2, 14), calendar: calendar), .valentines)
    }

    func testTodaysThemeIsHalloweenOverFall() {
        let theme = SeasonCalendar.theme(for: date(2026, 10, 30), southern: false, calendar: calendar)
        XCTAssertEqual(theme.season, .fall)
        XCTAssertEqual(theme.moment, .halloween)
        XCTAssertEqual(theme.recipe.primary, ["Spooky", "Eerie"])
        XCTAssertEqual(theme.particles, .embers)
    }

    func testTheNoteIconComesOutForFall() {
        let halloween = SeasonCalendar.theme(for: date(2026, 10, 30), southern: false, calendar: calendar)
        let winter = SeasonCalendar.theme(for: date(2027, 1, 15), southern: false, calendar: calendar)
        XCTAssertEqual(AppIconChoice.choice(chosen: .headphones, matchSeason: true, theme: halloween), .note)
        XCTAssertEqual(AppIconChoice.choice(chosen: .record, matchSeason: true, theme: winter), .record)
        XCTAssertEqual(AppIconChoice.choice(chosen: .headphones, matchSeason: false, theme: halloween), .headphones)
    }

    func testStPatricksDayIsTheFourDaysUpToTheSeventeenth() {
        XCTAssertNil(SeasonCalendar.moment(for: date(2027, 3, 13), calendar: calendar))
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 3, 14, hour: 0), calendar: calendar), .stPatricks)
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 3, 17, hour: 23), calendar: calendar), .stPatricks)
        XCTAssertNil(SeasonCalendar.moment(for: date(2027, 3, 18, hour: 0), calendar: calendar))
        // Everywhere, and on top of whichever season it is there.
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 3, 16), calendar: calendar, region: Locale.Region("IE")), .stPatricks)
        let sydney = SeasonCalendar.theme(for: date(2027, 3, 16), southern: true, calendar: calendar, region: Locale.Region("AU"))
        XCTAssertEqual(sydney.moment, .stPatricks)
        XCTAssertEqual(sydney.season, .fall)

        let theme = SeasonCalendar.theme(for: date(2027, 3, 16), southern: false, calendar: calendar)
        XCTAssertEqual(theme.title, "St. Patrick's")
        XCTAssertEqual(theme.season, .spring)
        XCTAssertEqual(theme.particles, .shamrocks)
        XCTAssertEqual(theme.recipe.primary, ["Rollicking", "Boisterous", "Rowdy"])
        XCTAssertEqual(theme.recipe.secondary, ["Joyous", "Lively", "Celebratory"])
    }

    func testTheFourthOfJulyIsOnlyInTheUS() {
        let us = Locale.Region.unitedStates
        XCTAssertNil(SeasonCalendar.moment(for: date(2027, 6, 30, hour: 23), calendar: calendar, region: us))
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 7, 1, hour: 0), calendar: calendar, region: us), .fourthOfJuly)
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 7, 4, hour: 23), calendar: calendar, region: us), .fourthOfJuly)
        XCTAssertNil(SeasonCalendar.moment(for: date(2027, 7, 5, hour: 0), calendar: calendar, region: us))
        XCTAssertEqual(SeasonCalendar.moment(for: date(2027, 7, 4), calendar: calendar, region: Locale.Region("PR")), .fourthOfJuly,
                       "US territories celebrate it too")

        for elsewhere in [Locale.Region("GB"), Locale.Region("CA"), Locale.Region("AU"), nil] {
            XCTAssertNil(SeasonCalendar.moment(for: date(2027, 7, 4), calendar: calendar, region: elsewhere))
            let theme = SeasonCalendar.theme(for: date(2027, 7, 4), southern: false, calendar: calendar, region: elsewhere)
            XCTAssertNil(theme.moment, "plain summer outside the US (\(elsewhere?.identifier ?? "no region"))")
            XCTAssertEqual(theme.title, "Summer")
        }

        let fourth = SeasonCalendar.theme(for: date(2027, 7, 3), southern: false, calendar: calendar, region: us)
        XCTAssertEqual(fourth.title, "Fourth of July")
        XCTAssertEqual(fourth.season, .summer)
        XCTAssertEqual(fourth.recipe.primary, ["Anthemic", "Rousing", "Triumphant"])
        XCTAssertEqual(fourth.recipe.secondary, ["Celebratory", "Summery"])
        XCTAssertTrue(fourth.decor.contains(.fireworks))
    }

    func testEachThemeBringsItsOwnTouches() {
        func decor(_ year: Int, _ month: Int, _ day: Int) -> SeasonTheme.Decor {
            SeasonCalendar.theme(for: date(year, month, day), southern: false, calendar: calendar, region: .unitedStates).decor
        }
        XCTAssertEqual(decor(2026, 9, 20), [.moon, .pumpkins], "fall")
        XCTAssertEqual(decor(2026, 10, 30), [.moon, .pumpkins], "Halloween")
        XCTAssertEqual(decor(2026, 11, 24), [.moon, .pumpkins], "Thanksgiving")
        XCTAssertEqual(decor(2026, 12, 15), [.sleigh, .snowCaps], "the holidays")
        XCTAssertEqual(decor(2026, 12, 31), [.fireworks], "New Year")
        XCTAssertEqual(decor(2027, 1, 20), [.snowCaps], "winter")
        XCTAssertEqual(decor(2027, 2, 12), [], "Valentine's")
        XCTAssertEqual(decor(2027, 3, 16), [.rainbow], "St. Patrick's")
        XCTAssertEqual(decor(2027, 4, 20), [.butterflies], "spring")
        XCTAssertEqual(decor(2027, 7, 3), [.fireworks], "the Fourth")
        XCTAssertEqual(decor(2027, 7, 20), [], "summer")
    }

    /// Mix covers come from scripts/generate-art.py; a moment without one shows a bare gradient.
    func testEveryMomentAndSeasonHasCoverArt() {
        for key in Moment.allCases.map(\.rawValue) + Season.allCases.map(\.rawValue) {
            XCTAssertNotNil(UIImage(named: "Mix-\(key)"), "Mix-\(key) is missing from the asset catalog")
        }
        for prop in ["sleigh", "pumpkin", "gourd", "jackOLantern"] {
            XCTAssertNotNil(UIImage(named: "Prop-\(prop)"), "Prop-\(prop) is missing from the asset catalog")
        }
    }

    func testAutomaticHemisphereGoesByTimeZone() {
        XCTAssertFalse(Hemisphere.automatic.isSouthern(timeZone: TimeZone(identifier: "America/Chicago")!))
        XCTAssertTrue(Hemisphere.automatic.isSouthern(timeZone: TimeZone(identifier: "Australia/Sydney")!))
        XCTAssertTrue(Hemisphere.southern.isSouthern(timeZone: TimeZone(identifier: "America/Chicago")!))
    }
}
