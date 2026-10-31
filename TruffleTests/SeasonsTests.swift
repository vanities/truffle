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

    func testAutomaticHemisphereGoesByTimeZone() {
        XCTAssertFalse(Hemisphere.automatic.isSouthern(timeZone: TimeZone(identifier: "America/Chicago")!))
        XCTAssertTrue(Hemisphere.automatic.isSouthern(timeZone: TimeZone(identifier: "Australia/Sydney")!))
        XCTAssertTrue(Hemisphere.southern.isSouthern(timeZone: TimeZone(identifier: "America/Chicago")!))
    }
}
