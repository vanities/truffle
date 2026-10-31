import XCTest
@testable import Truffle

/// Shuffle All and Album Roulette end to end against the in-app demo ("Take it for a spin"), whose only
/// holiday music is "A Low Tide Christmas": 6 of its 154 songs.
final class HolidayShuffleTests: XCTestCase {
    private static let holidayAlbum = "A Low Tide Christmas"

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private var july: Date { calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 9))! }
    private var december: Date { calendar.date(from: DateComponents(year: 2026, month: 12, day: 10, hour: 18))! }

    @MainActor
    func testShuffleAllSavesHolidayMusicForTheHolidaysInTheSameRound() async throws {
        let library = try await demoLibrary()
        XCTAssertEqual(library.holidays.songs, 6, "counted by title searches and the album list")

        var july: [Track] = []
        while july.count < 100 { july += try await library.nextShuffled(1, now: self.july) }
        XCTAssertFalse(july.contains(where: HolidayMusic.isHoliday), "no holiday music in July")

        var december: [Track] = []
        while library.walk?.isExhausted == false { december += try await library.nextShuffled(1, now: self.december) }
        let round = july + december
        XCTAssertEqual(library.walk?.round, 1)
        XCTAssertEqual(round.count, 154)
        XCTAssertEqual(Set(round.map(\.id)).count, 154, "every song once, holiday songs included, nothing twice")
        XCTAssertEqual(december.filter(HolidayMusic.isHoliday).count, 6, "they waited in the round for December")
        XCTAssertEqual(library.holidays.positions.count, 6, "and the walk remembers where they are")
    }

    @MainActor
    func testWithTheSettingOffHolidayMusicShufflesAllYear() async throws {
        let library = try await demoLibrary()
        library.settings.holidaysInSeason = false
        var round: [Track] = []
        while round.count < 154 { round += try await library.nextShuffled(1, now: july) }
        XCTAssertEqual(Set(round.map(\.id)).count, 154)
        XCTAssertEqual(round.filter(HolidayMusic.isHoliday).count, 6)
    }

    @MainActor
    func testRouletteLeavesTheHolidayAlbumForTheHolidays() async throws {
        let library = try await demoLibrary()
        for _ in 0..<40 {
            let spin = try await library.randomAlbumTracks(now: july)
            let (album, tracks) = try XCTUnwrap(spin)
            XCTAssertNotEqual(album.title, Self.holidayAlbum)
            XCTAssertFalse(tracks.isEmpty)
        }
    }

    // MARK: - Helpers

    /// A library on the in-app demo with its own settings and store, signed out (which stops the demo
    /// server and forgets it) when the test ends.
    @MainActor
    private func demoLibrary() async throws -> MusicLibrary {
        let suite = "HolidayShuffleTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appending(path: "holiday-shuffle-\(UUID().uuidString)")
        let library = MusicLibrary(identity: .current(), settings: AppSettings(defaults: defaults),
                                   store: LibraryStore(directory: directory))
        library.startDemo()
        addTeardownBlock { @MainActor in
            library.signOut()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let deadline = Date.now.addingTimeInterval(15)
        while library.phase != .ready || library.holidays.countedAt == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.phase, .ready)
        XCTAssertEqual(library.trackCount, 154)
        return library
    }
}
