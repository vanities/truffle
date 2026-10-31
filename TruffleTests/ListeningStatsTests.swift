import XCTest
@testable import Truffle

final class ListeningStatsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func play(_ id: String, _ when: Date) -> PlayRecord {
        PlayRecord(trackID: id, viewedAt: Int(when.timeIntervalSince1970))
    }

    private func song(_ title: String, artist: String = "Ana", album: String = "Album", albumID: String? = "album",
                      albumArtist: String? = nil, duration: TimeInterval = 200, viewCount: Int? = nil,
                      lastViewedAt: Date? = nil, inLibrary: Bool = true) -> SongFacts {
        SongFacts(title: title, artist: artist, album: album, albumID: albumID, albumArtist: albumArtist ?? artist,
                  albumArtistID: "id-\(albumArtist ?? artist)", duration: duration, viewCount: viewCount,
                  lastViewedAt: lastViewedAt.map { Int($0.timeIntervalSince1970) }, inLibrary: inLibrary)
    }

    /// Friday, October 30, 2026, 9 pm in Chicago.
    private var now: Date { date(2026, 10, 30, 21) }

    private func build(_ plays: [PlayRecord], _ songs: [String: SongFacts], now: Date? = nil, library: Int = 0) -> ListeningStats {
        ListeningStats.build(plays: plays, songs: songs, libraryTrackCount: library, now: now ?? self.now, calendar: calendar)
    }

    func testTotalsForTheWeekMonthYearAndAllTime() {
        let songs = ["a": song("A", duration: 200), "b": song("B", artist: "Bo", duration: 100), "c": song("C", artist: "Cy", duration: 300)]
        let stats = build([
            play("c", date(2025, 12, 31, 23, 30)),
            play("c", date(2026, 3, 3)),
            play("b", date(2026, 10, 20)),
            play("a", date(2026, 10, 26)),
            play("a", date(2026, 10, 30, 8)),
        ], songs)
        XCTAssertEqual(stats.total(.week), .init(plays: 2, seconds: 400, songs: 1, artists: 1))
        XCTAssertEqual(stats.total(.month), .init(plays: 3, seconds: 500, songs: 2, artists: 2))
        XCTAssertEqual(stats.total(.year), .init(plays: 4, seconds: 800, songs: 3, artists: 3))
        XCTAssertEqual(stats.total(.all), .init(plays: 5, seconds: 1100, songs: 3, artists: 3), "New Year's Eve counts only toward all time")
    }

    func testAWeekCanStartLastMonth() {
        // Tuesday, December 1: the week began Sunday, November 29.
        let stats = build([play("a", date(2026, 11, 28)), play("a", date(2026, 11, 29))], ["a": song("A")], now: date(2026, 12, 1, 10))
        XCTAssertEqual(stats.total(.week).plays, 1)
        XCTAssertEqual(stats.total(.month).plays, 0)
        XCTAssertEqual(stats.total(.year).plays, 2)
    }

    func testStreaksGoByLocalDaysAndMayEndYesterday() {
        let run = (1...5).map { play("a", date(2026, 9, $0)) }
        // 11:30 pm in Chicago is already the 30th in UTC; it belongs to the 29th here.
        let recent = [play("a", date(2026, 10, 27)), play("a", date(2026, 10, 28)), play("a", date(2026, 10, 29, 23, 30))]
        let stats = build(run + recent, ["a": song("A")])
        XCTAssertEqual(stats.currentStreak, 3, "nothing yet today doesn't break it")
        XCTAssertEqual(stats.longestStreak, 5)
        XCTAssertEqual(stats.daysListened, 8)
        XCTAssertEqual(build(run + recent, ["a": song("A")], now: date(2026, 11, 1, 9)).currentStreak, 0, "a missed day does")
    }

    func testTopListsRankByPlaysThenRecency() {
        let songs = [
            "a": song("A", album: "X", albumID: "x"),
            "b": song("B", album: "X", albumID: "x"),
            "c": song("C", artist: "Bo", album: "Y", albumID: "y"),
            "d": song("D", artist: "Guest", album: "Comp", albumID: "z", albumArtist: "Various Artists"),
        ]
        let plays = (1...3).map { play("a", date(2026, 9, $0)) } + (10...12).map { play("b", date(2026, 10, $0)) }
            + [play("c", date(2026, 10, 1)), play("d", date(2026, 8, 1)), play("d", date(2026, 8, 2))]
        let top = build(plays, songs).top(.all)
        XCTAssertEqual(top.songs.map(\.id), ["b", "a", "d", "c"], "a tie goes to the more recently played")
        XCTAssertEqual(top.artists.map(\.title), ["Ana", "Guest", "Bo"])
        XCTAssertEqual(top.artists.map(\.plays), [6, 2, 1])
        XCTAssertEqual(top.artists[0].artistID, "id-Ana")
        XCTAssertNil(top.artists[1].artistID, "a compilation's guest has no artist page")
        XCTAssertEqual(top.albums.map(\.title), ["X", "Comp", "Y"])
        XCTAssertEqual(top.albums[1].subtitle, "Various Artists")
        XCTAssertEqual(top.songs[0].trackID, "b")
    }

    func testTwelveMonthsZeroFilledWithTheBest() {
        let plays = [play("a", date(2025, 10, 15)), play("a", date(2025, 11, 2))] + (1...3).map { play("a", date(2026, 10, $0)) }
        let stats = build(plays, ["a": song("A")])
        XCTAssertEqual(stats.months.count, 12)
        XCTAssertEqual(stats.months.first?.start, date(2025, 11, 1, 0))
        XCTAssertEqual(stats.months.map(\.plays), [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3], "October 2025 is outside the window")
        XCTAssertEqual(stats.bestMonth?.start, date(2026, 10, 1, 0))
    }

    func testBusiestHourAndWeekday() {
        // October 23 and 30 are Fridays; the 26th a Monday.
        let plays = [play("a", date(2026, 10, 23, 18, 5)), play("a", date(2026, 10, 30, 18, 40)), play("a", date(2026, 10, 30, 18, 50)),
                     play("a", date(2026, 10, 26, 8)), play("a", date(2026, 10, 26, 8, 30))]
        let stats = build(plays, ["a": song("A")])
        XCTAssertEqual(stats.busiestHour, 18)
        XCTAssertEqual(stats.busiestWeekday, 6)
        XCTAssertEqual(stats.byHour[8], 2)
        XCTAssertNil(build([], [:]).busiestHour)
    }

    func testASongWithNoLengthOnRecordCountsAsAnAverageOne() {
        let stats = build([play("a", date(2026, 10, 1)), play("b", date(2026, 10, 2)), play("gone", date(2026, 10, 3))],
                          ["a": song("A", duration: 100), "b": song("B", duration: 300)])
        XCTAssertEqual(stats.total(.all).seconds, 600)
    }

    func testLongTimeNoHearTakesPlexsOwnCountsIntoAccount() {
        let january = (1...5).map { date(2026, 1, $0) }
        let songs = [
            "old": song("Old"),
            "counted": song("Counted", viewCount: 9, lastViewedAt: date(2026, 2, 1)),
            "playedElsewhere": song("Played elsewhere", lastViewedAt: date(2026, 10, 1)),
            "rare": song("Rare"),
            "gone": song("Gone", inLibrary: false),
            "recent": song("Recent"),
        ]
        let plays = january.prefix(4).map { play("old", $0) } + [play("counted", date(2026, 2, 1))]
            + january.map { play("playedElsewhere", $0) } + january.prefix(2).map { play("rare", $0) }
            + january.map { play("gone", $0) } + (1...5).map { play("recent", date(2026, 10, $0)) }
        let missed = build(plays, songs).longTimeNoHear
        XCTAssertEqual(missed.map(\.id), ["counted", "old"])
        XCTAssertEqual(missed.map(\.plays), [9, 4])
        XCTAssertEqual(missed.first?.lastPlayed, date(2026, 2, 1))
    }

    func testFirstPlayAndHowMuchOfTheLibraryHasBeenHeard() {
        let stats = build([play("b", date(2024, 5, 1)), play("gone", date(2024, 3, 1)), play("a", date(2024, 4, 1))],
                          ["a": song("A"), "b": song("B"), "gone": song("Gone", inLibrary: false)], library: 8)
        XCTAssertEqual(stats.firstPlay?.date, date(2024, 3, 1))
        XCTAssertEqual(stats.firstPlay?.song.title, "Gone")
        XCTAssertNil(stats.firstPlay?.song.trackID, "a song that's gone can't be played")
        XCTAssertEqual(stats.songsHeard, 2)
        XCTAssertEqual(stats.libraryShare, 0.25)
    }

    func testNoPlaysIsEmpty() {
        let stats = build([], ["a": song("A")])
        XCTAssertTrue(stats.isEmpty)
        XCTAssertNil(stats.firstPlay)
        XCTAssertTrue(stats.top(.all).isEmpty)
    }

    // MARK: - Reading history

    func testAnUpdateAppendsWhenTheOverlapLinesUp() {
        let saved = (1...3).map { PlayRecord(trackID: "s\($0)", viewedAt: $0) }
        let later = (4...5).map { PlayRecord(trackID: "s\($0)", viewedAt: $0) }
        XCTAssertEqual(HistorySync.resumeIndex(cached: saved.count), 2)
        XCTAssertEqual(HistorySync.merge(cached: saved, fetched: [saved[2]] + later, total: 5), saved + later)
        XCTAssertEqual(HistorySync.merge(cached: saved, fetched: [saved[2]], total: 3), saved, "nothing new")
        XCTAssertEqual(HistorySync.merge(cached: [], fetched: later, total: 2), later)
    }

    func testAnUpdateStartsOverWhenHistoryMoved() {
        let saved = (1...3).map { PlayRecord(trackID: "s\($0)", viewedAt: $0) }
        XCTAssertNil(HistorySync.merge(cached: saved, fetched: [], total: 2), "a play was deleted")
        XCTAssertNil(HistorySync.merge(cached: saved, fetched: [saved[1], saved[2]], total: 4), "one was back-dated in")
    }

    func testPagesAfterTheFirst() {
        XCTAssertEqual(HistorySync.pageStarts(after: 0, size: 1000, total: 2500), [1000, 2000])
        XCTAssertEqual(HistorySync.pageStarts(after: 4_999, size: 1000, total: 5_000), [])
        XCTAssertEqual(HistorySync.resumeIndex(cached: 0), 0)
    }

    func testHistoryEntriesBecomePlays() throws {
        // The shape of PMS 1.43's history: librarySectionID as a string, accountID and deviceID as numbers.
        let json = """
        {"MediaContainer": {"size": 3, "totalSize": 3, "Metadata": [
          {"historyKey": "/status/sessions/history/9", "key": "/library/metadata/3001", "ratingKey": "3001",
           "librarySectionID": "3", "parentKey": "/library/metadata/2001", "grandparentKey": "/library/metadata/1001",
           "title": "Song", "grandparentTitle": "Artist", "parentTitle": "Album", "type": "track",
           "parentRatingKey": "2001", "viewedAt": 1793399270, "accountID": 1, "deviceID": 7},
          {"ratingKey": "77", "type": "episode", "title": "Not music", "viewedAt": 1793399300},
          {"ratingKey": "3002", "type": "track", "title": "No date"}
        ]}}
        """
        let container = try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: Data(json.utf8)).container
        var read = HistoryRead()
        read.add(container.metadata)
        XCTAssertEqual(read.plays, [PlayRecord(trackID: "3001", viewedAt: 1_793_399_270)])
        XCTAssertEqual(read.named["3001"]?.artist, "Artist")
        XCTAssertEqual(read.named["3001"]?.album, "Album")
        XCTAssertEqual(read.named["3001"]?.inLibrary, false)
        XCTAssertNil(read.named["3001"]?.albumID, "a history entry's ids lead nowhere once the song is gone")
    }

    func testSongFactsFromTheLibrary() throws {
        let json = """
        {"MediaContainer": {"Metadata": [
          {"ratingKey": "1", "type": "track", "title": "Own", "grandparentTitle": "Band", "grandparentRatingKey": "10",
           "parentTitle": "LP", "parentRatingKey": "20", "parentThumb": "/t/20", "duration": 241000, "viewCount": 7,
           "lastViewedAt": 1790000000},
          {"ratingKey": "2", "type": "track", "title": "Guest spot", "originalTitle": "Guest", "grandparentTitle": "Various Artists",
           "grandparentRatingKey": "11", "parentTitle": "Comp", "parentRatingKey": "21"}
        ]}}
        """
        let items = try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: Data(json.utf8)).container.metadata
        let own = try XCTUnwrap(SongFacts(items[0]))
        XCTAssertEqual(own.duration, 241)
        XCTAssertEqual(own.viewCount, 7)
        XCTAssertEqual(own.lastViewedAt, 1_790_000_000)
        XCTAssertEqual(own.thumb, "/t/20")
        XCTAssertEqual(own.artistPageID, "10")
        let guest = try XCTUnwrap(SongFacts(items[1]))
        XCTAssertEqual(guest.artist, "Guest")
        XCTAssertEqual(guest.albumArtist, "Various Artists")
        XCTAssertNil(guest.artistPageID)
    }

    func testSavedStatsSurviveARoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        let cache = StatsCache(machineIdentifier: "m", sectionID: "3", accountID: "1",
                               plays: [PlayRecord(trackID: "1", viewedAt: 5)], songs: ["1": song("A")])
        store.save(cache, to: "stats-3.json")
        let loaded = try XCTUnwrap(store.load(StatsCache.self, from: "stats-3.json"))
        XCTAssertEqual(loaded.plays, cache.plays)
        XCTAssertEqual(loaded.songs, cache.songs)
        XCTAssertEqual(loaded.accountID, "1")
    }

    func testListeningTimeReadsAtAGlance() {
        XCTAssertEqual(TimeInterval(0).statsDuration, "0 min")
        XCTAssertEqual(TimeInterval(47 * 60).statsDuration, "47 min")
        XCTAssertEqual(TimeInterval(3 * 3600 + 12 * 60).statsDuration, "3 hr 12 min")
        XCTAssertEqual(TimeInterval(3 * 3600).statsDuration, "3 hr")
        XCTAssertEqual(TimeInterval(241 * 3600 + 50 * 60).statsDuration, "241 hr")
        XCTAssertEqual(TimeInterval(1234 * 3600).statsDuration, "1,234 hr")
    }
}
