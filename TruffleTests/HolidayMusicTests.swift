import XCTest
@testable import Truffle

final class HolidayMusicTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testHolidayTitlesMatch() {
        let titles = [
            "Jingle Bell Rock", "Santa Claus Is Comin' to Town", "Santa’s Workshop", "Feliz Navidad", "The First Noël",
            "Silent Night", "Sleigh Ride", "Have Yourself a Merry Little Christmas", "Christmastime Is Here",
            "Happy Xmas (War Is Over)", "Mistletoe and Holly", "Deck the Hall", "O Holy Night", "Oh Holy Night",
            "Frosty the Snowman", "Rudolph the Red-Nosed Reindeer", "Hark! The Herald Angels Sing", "Joy to the World",
            "Happy Holidays", "Home for the Holidays", "CHRISTMAS IN HOLLIS", "Santa Claus Lane in Santa Monica",
        ]
        for title in titles {
            XCTAssertTrue(HolidayMusic.matches(title), title)
        }
    }

    func testLookalikesAndNearMissesDont() {
        let titles = [
            "Santa Monica", "Santa Fe", "Santana Jam", "Merry-Go-Round", "Holiday in Cambodia", "Holiday Road",
            "Roman Holiday", "Holidays in the Sun", "Jingle Jangle", "Feliz Cumpleaños", "Noelle", "Merryweather",
            "First Frost", "Silent Bells", "Polar Night", "Frostbite", "Christ Is Risen", "",
        ]
        for title in titles {
            XCTAssertFalse(HolidayMusic.matches(title), title)
        }
    }

    func testASongCountsByItsAlbumTitleToo() {
        XCTAssertTrue(HolidayMusic.isHoliday(Track(id: "1", title: "Last Swim of the Year", artist: "Low Tide Club", album: "A Low Tide Christmas")))
        XCTAssertTrue(HolidayMusic.isHoliday(Track(id: "2", title: "Mistletoe Marina", artist: "Low Tide Club", album: "Sand")))
        XCTAssertFalse(HolidayMusic.isHoliday(Track(id: "3", title: "Riptide", artist: "Low Tide Club", album: "Riptide")))
    }

    func testTheHolidaysRunFromTheDayAfterThanksgivingThroughNewYearsDay() {
        XCTAssertFalse(HolidayMusic.isInSeason(date(2026, 7, 10), calendar: calendar))
        XCTAssertFalse(HolidayMusic.isInSeason(date(2026, 10, 30), calendar: calendar))
        XCTAssertFalse(HolidayMusic.isInSeason(date(2026, 11, 26), calendar: calendar), "Thanksgiving itself")
        XCTAssertTrue(HolidayMusic.isInSeason(date(2026, 11, 27, hour: 0), calendar: calendar))
        XCTAssertTrue(HolidayMusic.isInSeason(date(2026, 12, 10), calendar: calendar))
        XCTAssertTrue(HolidayMusic.isInSeason(date(2026, 12, 31), calendar: calendar))
        XCTAssertTrue(HolidayMusic.isInSeason(date(2027, 1, 1, hour: 23), calendar: calendar))
        XCTAssertFalse(HolidayMusic.isInSeason(date(2027, 1, 2, hour: 0), calendar: calendar))
    }

    func testEveryPhraseIsFoundByOneOfTheSearches() {
        // Plex's `title=` matches substrings, so each phrase has to hold one of the words asked for.
        for phrase in HolidayMusic.phrases {
            XCTAssertTrue(HolidayMusic.searchTerms.contains { phrase.lowercased().contains($0) }, phrase)
        }
    }

    func testCountsAlbumSongsOnceAndSearchHitsOnlyWhenTheyMatch() {
        let albums = [Album(id: "a1", title: "A Low Tide Christmas", artist: "Low Tide Club", trackCount: 6),
                      Album(id: "a2", title: "Riptide", artist: "Low Tide Club", trackCount: 6)]
        let jingle = Track(id: "t2", title: "Jingle Bell Rock", artist: "B", album: "Hits", albumID: "a3")
        let titled = [
            Track(id: "t1", title: "Santa Hangs Ten", artist: "Low Tide Club", album: "A Low Tide Christmas", albumID: "a1"),
            jingle, jingle,
            Track(id: "t3", title: "Santa Monica", artist: "E", album: "Sparkle", albumID: "a4"),
        ]
        XCTAssertEqual(HolidayMusic.count(albums: albums, titled: titled), 7,
                       "the album's 6, Jingle Bell Rock once though two searches found it, and not Santa Monica")
    }

    func testTheDemosOnlyHolidayMusicIsItsHolidayAlbum() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "demo-catalog", withExtension: "json"))
        let library = try DemoLibrary(catalogURL: catalog)
        let holiday = library.tracks.filter { HolidayMusic.matches($0.title) || HolidayMusic.matches($0.albumTitle) }
        XCTAssertEqual(holiday.map(\.title), ["Santa Hangs Ten", "Sleigh Bells on the Boardwalk", "Mistletoe Marina",
                                              "Silent Night Swim", "Frosty the Sandman", "Last Swim of the Year"])
        XCTAssertEqual(Set(holiday.map(\.albumTitle)), ["A Low Tide Christmas"])
    }
}
