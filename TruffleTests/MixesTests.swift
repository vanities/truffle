import XCTest
@testable import Truffle

final class MixesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func track(_ id: String) -> Track { Track(id: id, title: id, artist: "A", album: "B") }

    func testThisTimeLastYearReadsTwoWeeksEitherSideBackToTheFirstPlay() {
        // History on this server starts 2024-02-27.
        let windows = HistoryWindows.aroundThisDate(date(2026, 10, 30), earliest: date(2024, 2, 27), calendar: calendar)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, date(2025, 10, 16, hour: 0))
        XCTAssertEqual(windows[0].end, date(2025, 11, 14, hour: 0))
        XCTAssertEqual(windows[1].start, date(2024, 10, 16, hour: 0))
    }

    func testSeasonWindowsAreFinishedSeasonsOnly() {
        let falls = HistoryWindows.seasonWindows(.fall, southern: false, before: date(2026, 10, 30), earliest: date(2024, 2, 27), calendar: calendar)
        XCTAssertEqual(falls.map(\.start), [date(2025, 9, 1, hour: 0), date(2024, 9, 1, hour: 0)])
        XCTAssertEqual(falls[0].end, date(2025, 12, 1, hour: 0))

        let winters = HistoryWindows.seasonWindows(.winter, southern: false, before: date(2026, 10, 30), earliest: date(2024, 2, 27), calendar: calendar)
        XCTAssertEqual(winters.map(\.start), [date(2025, 12, 1, hour: 0), date(2024, 12, 1, hour: 0), date(2023, 12, 1, hour: 0)],
                       "the winter that ended Feb 29, 2024 still overlaps the first play")
    }

    func testMoodMixLeadsWithPrimaryMoodsAndNeverRepeats() {
        var generator = SeededGenerator(seed: 5)
        let primary = (0..<10).map { track("p\($0)") }
        let secondary = (0..<50).map { track("s\($0)") } + [track("p1")]
        let mix = MixBuilder.moodMix(primary: primary, secondary: secondary, limit: 30, using: &generator)
        XCTAssertEqual(mix.count, 30)
        XCTAssertEqual(Set(mix.map(\.id)).count, 30, "no repeats, even when a song has both moods")
        XCTAssertTrue(Set(primary.map(\.id)).isSubset(of: Set(mix.map(\.id))), "every primary-mood song makes it in")
    }

    func testMoodMixCapsABigPrimarySet() {
        var generator = SeededGenerator(seed: 6)
        let mix = MixBuilder.moodMix(primary: (0..<500).map { track("p\($0)") }, secondary: [track("s")], limit: 100, using: &generator)
        XCTAssertEqual(mix.count, 100)
        XCTAssertFalse(mix.contains { $0.id == "s" })
    }

    func testFavoritesRankByPlays() {
        XCTAssertEqual(MixBuilder.favorites(plays: ["a", "b", "a", "c", "b", "a", "d"], limit: 3), ["a", "b", "c"])
        XCTAssertEqual(MixBuilder.distinct(["x", "y", "x"]), ["x", "y"])
    }

    func testTonightsMixes() {
        let theme = SeasonCalendar.theme(for: date(2026, 10, 30, hour: 21), southern: false, calendar: calendar)
        let mixes = MixPlanner.seasonal(theme: theme, date: date(2026, 10, 30, hour: 21), calendar: calendar)
        XCTAssertEqual(mixes.map(\.kind), [.moment, .season, .lastYear, .seasonFavorites, .nightDrive])
        XCTAssertEqual(mixes.first?.title, "Halloween Mix")

        // Outside the US, the Fourth is a summer morning: no moment, no Night Drive.
        let london = SeasonCalendar.theme(for: date(2026, 7, 4, hour: 9), southern: false, calendar: calendar, region: Locale.Region("GB"))
        let morning = MixPlanner.seasonal(theme: london, date: date(2026, 7, 4, hour: 9), calendar: calendar)
        XCTAssertEqual(morning.map(\.kind), [.season, .lastYear, .seasonFavorites])
    }

    func testTheFourthsMixLeadsInTheUS() {
        let evening = date(2027, 7, 3, hour: 21)
        let theme = SeasonCalendar.theme(for: evening, southern: false, calendar: calendar, region: .unitedStates)
        let mixes = MixPlanner.seasonal(theme: theme, date: evening, calendar: calendar)
        XCTAssertEqual(mixes.map(\.kind), [.moment, .season, .lastYear, .seasonFavorites, .nightDrive])
        XCTAssertEqual(mixes.first?.title, "Fourth of July Mix")
        XCTAssertEqual(mixes.first?.art, "fourthOfJuly")
        XCTAssertEqual(mixes[1].title, "Summer Mix")
    }

    func testStPatricksMixInTheSpring() {
        let theme = SeasonCalendar.theme(for: date(2027, 3, 16, hour: 19), southern: false, calendar: calendar)
        let mixes = MixPlanner.seasonal(theme: theme, date: date(2027, 3, 16, hour: 19), calendar: calendar)
        XCTAssertEqual(mixes.map(\.kind), [.moment, .season, .lastYear, .seasonFavorites])
        XCTAssertEqual(mixes.first?.art, "stPatricks")
        XCTAssertEqual(mixes[1].title, "Spring Mix")
    }

    func testTheNewYearMixIsFiledUnderTheYearItRingsIn() {
        XCTAssertEqual(MixBuilder.mixYear(theme: "newyear", on: date(2026, 12, 29), calendar: calendar), 2027,
                       "New Year's Eve plays the mix named for next year")
        XCTAssertEqual(MixBuilder.mixYear(theme: "newyear", on: date(2027, 1, 1), calendar: calendar), 2027)
        XCTAssertEqual(MixBuilder.mixYear(theme: "christmas", on: date(2026, 12, 20), calendar: calendar), 2026,
                       "every other theme goes by the calendar")
        XCTAssertEqual(MixBuilder.mixYear(theme: "thanksgiving", on: date(2026, 11, 26), calendar: calendar), 2026)
    }

    func testAMadeMixIsKeptForItsSeasonAndTheRandomOnesAreNot() {
        let fall = Mix(kind: .season, title: "Fall Mix", subtitle: "", symbol: "leaf", art: "fall")
        let thanksgiving = Mix(kind: .moment, title: "Thanksgiving Mix", subtitle: "", symbol: "fork.knife", art: "thanksgiving")
        let key = MixBuilder.saveKey(for: fall, on: date(2026, 11, 26), calendar: calendar)
        XCTAssertEqual(key, MixBuilder.saveKey(for: fall, on: date(2026, 9, 30), calendar: calendar), "one draw for the whole season")
        XCTAssertNotEqual(key, MixBuilder.saveKey(for: fall, on: date(2027, 10, 1), calendar: calendar), "next fall gets its own")
        XCTAssertNotEqual(key, MixBuilder.saveKey(for: thanksgiving, on: date(2026, 11, 26), calendar: calendar))
        XCTAssertNil(MixBuilder.saveKey(for: .shuffleAll, on: date(2026, 11, 26), calendar: calendar), "Shuffle All is never the same twice")
        XCTAssertNil(MixBuilder.saveKey(for: .randomAlbum, on: date(2026, 11, 26), calendar: calendar))
        XCTAssertNil(MixBuilder.saveKey(for: .liked, on: date(2026, 11, 26), calendar: calendar))
    }

    func testThisTimeLastYearIsMadeAgainEachWeek() {
        let lastYear = Mix(kind: .lastYear, title: "This Time Last Year", subtitle: "", symbol: "clock")
        let monday = MixBuilder.saveKey(for: lastYear, on: date(2026, 11, 23), calendar: calendar)
        XCTAssertEqual(monday, MixBuilder.saveKey(for: lastYear, on: date(2026, 11, 26), calendar: calendar))
        XCTAssertNotEqual(monday, MixBuilder.saveKey(for: lastYear, on: date(2026, 12, 3), calendar: calendar),
                          "its two weeks either side of today have moved on")
    }
}
