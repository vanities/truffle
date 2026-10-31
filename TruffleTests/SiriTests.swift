import Intents
import XCTest
@testable import Truffle

@MainActor
final class FakeCatalog: MediaCatalog {
    var playlists: [Playlist] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var results = SearchResults()
    private(set) var searches: [String] = []

    func search(_ text: String, limit: Int) async throws -> SearchResults {
        searches.append(text)
        return results
    }
}

@MainActor
final class SiriTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private let us = Locale.Region("US")

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func mixes(_ date: Date) -> [MixCatalog.Entry] {
        MixCatalog.all(at: date, southern: false, calendar: calendar, region: us)
    }

    private let roadTrip = Playlist(id: "p1", title: "Road Trip", isSmart: false, trackCount: 40)
    private let pumpkins = Playlist(id: "p2", title: "🎃 Halloween 2026", isSmart: false, trackCount: 25)
    private let everything = Playlist(id: "p3", title: "All the Things", isSmart: true, trackCount: 6_000)
    private let velvet = Artist(id: "a1", title: "Velvet Static")
    private let ana = Artist(id: "a2", title: "Ana Ríos")
    private let nightSwimming = Album(id: "b1", title: "Night Swimming", artist: "Velvet Static")
    private let aurora = Album(id: "b2", title: "Aurora", artist: "The Northern Lights Society")

    private func catalog() -> FakeCatalog {
        let catalog = FakeCatalog()
        catalog.playlists = [roadTrip, pumpkins, everything]
        catalog.artists = [velvet, ana]
        catalog.albums = [nightSwimming, aurora]
        return catalog
    }

    private func resolve(_ request: MediaRequest, in catalog: FakeCatalog? = nil, on day: Date? = nil) async -> PlaybackPlan? {
        await MediaSearchResolver.resolve(request, in: catalog ?? self.catalog(), mixes: mixes(day ?? date(2026, 10, 31)))
    }

    // MARK: - Names as Siri hears them

    func testNamesMatchWithoutCaseAccentsEmojiOrALeadingThe() {
        XCTAssertEqual(MediaText.key("🎃 Halloween 2026"), "halloween 2026")
        XCTAssertEqual(MediaText.key("Ana Ríos"), "ana rios")
        XCTAssertEqual(MediaText.key("The Lantern Hours"), "lantern hours")
        XCTAssertEqual(MediaText.key("Marrow & Moth"), "marrow and moth")
        XCTAssertEqual(MediaText.key("The The"), "the", "a name that's only \"the\" keeps it")
        XCTAssertEqual(MediaText.score("Halloween Mix", asked: "the halloween mix"), 3)
        XCTAssertEqual(MediaText.score("Halloween Party", asked: "Halloween"), 2)
        XCTAssertEqual(MediaText.score("Night Swimming", asked: "swimming"), 1)
        XCTAssertEqual(MediaText.score("Road Trip", asked: "Late Night"), 0)
    }

    // MARK: - Mixes by name

    func testTodaysMixesAreHomesAndEveryOtherHolidayIsThereByName() throws {
        let halloween = date(2026, 10, 31)
        let today = MixCatalog.today(at: halloween, southern: false, calendar: calendar, region: us)
        XCTAssertEqual(today.map(\.id), ["shuffleAll", "liked", "moment", "season", "lastYear", "seasonFavorites", "randomAlbum"])
        XCTAssertEqual(today.first { $0.id == "moment" }?.mix.title, "Halloween Mix")
        XCTAssertEqual(today.first { $0.id == "season" }?.mix.title, "Fall Mix")

        let all = MixCatalog.all(at: halloween, southern: false, calendar: calendar, region: us)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids are unique")
        XCTAssertTrue(all.contains { $0.id == "nightDrive" }, "Night Drive by name at noon too")
        let holidays = try XCTUnwrap(all.first { $0.id == "theme.christmas" })
        XCTAssertEqual(holidays.mix.title, "Holiday Mix")
        XCTAssertEqual(holidays.theme.moment, .christmas)
        XCTAssertFalse(all.contains { $0.id == "theme.halloween" || $0.id == "theme.fall" }, "today's aren't listed twice")
        XCTAssertFalse(MixCatalog.all(at: halloween, southern: false, calendar: calendar, region: Locale.Region("GB"))
            .contains { $0.id == "theme.fourthOfJuly" }, "the Fourth is a US mix")
    }

    func testAWidgetButtonOutlivingItsHolidayPlaysTheSeasonsMix() {
        let entry = MixCatalog.entry(id: "moment", at: date(2026, 11, 3), southern: false, calendar: calendar, region: us)
        XCTAssertEqual(entry?.mix.title, "Fall Mix")
        XCTAssertNil(MixCatalog.entry(id: "nope", at: date(2026, 11, 3), southern: false, calendar: calendar, region: us))
    }

    func testTheMixQueryKeepsTheIdItWasAskedFor() async throws {
        let entities = try await MixQuery().entities(for: ["moment", "liked", "nope"])
        XCTAssertEqual(entities.map(\.id), ["moment", "liked"], "a stale id still answers to itself")
        XCTAssertEqual(PlayMixIntent(mix: entities[1]).mix.title, "Liked")
    }

    // MARK: - What plays

    func testPlaylistsPlayFromTheTopUnlessShuffledAndBigOnesAlwaysShuffle() {
        XCTAssertEqual(PlaybackPlan.forPlaylist(roadTrip, shuffled: false), .playlist(roadTrip))
        XCTAssertEqual(PlaybackPlan.forPlaylist(roadTrip, shuffled: true), .shufflePlaylist(roadTrip))
        XCTAssertEqual(PlaybackPlan.forPlaylist(everything, shuffled: false), .shufflePlaylist(everything),
                       "6,000 songs shuffle by position instead of downloading")
    }

    func testASongPlaysOnIntoItsAlbum() {
        let song = Track(id: "t9", title: "Ember Waltz", artist: "Saint Ember", album: "Bonfire Hymns", albumID: "b9")
        XCTAssertEqual(PlaybackPlan.forSong(song), .album(Album(id: "b9", title: "Bonfire Hymns", artist: "Saint Ember"), startAt: "t9", shuffled: false))
        let loose = Track(id: "t10", title: "Loose", artist: "X", album: "Y")
        XCTAssertEqual(PlaybackPlan.forSong(loose), .song(loose))
    }

    // MARK: - Siri requests

    func testPlaySomeMusicIsShuffleAll() async {
        let plan = await resolve(MediaRequest())
        XCTAssertEqual(plan?.title, "Shuffle All")
        let music = await resolve(MediaRequest(kind: .any, name: "my music"))
        XCTAssertEqual(music?.title, "Shuffle All")
    }

    func testLikedSongsByAnyName() async {
        for name in ["my liked songs", "Liked", "the good stuff", "favorites"] {
            let plan = await resolve(MediaRequest(name: name))
            XCTAssertEqual(plan?.title, "Liked", name)
        }
    }

    func testPlaylistsByNameEvenWithoutTheEmoji() async {
        let road = await resolve(MediaRequest(kind: .playlist, name: "road trip"))
        XCTAssertEqual(road, .playlist(roadTrip))
        let shuffled = await resolve(MediaRequest(name: "Road Trip", shuffled: true))
        XCTAssertEqual(shuffled, .shufflePlaylist(roadTrip))
        let spooky = await resolve(MediaRequest(name: "halloween 2026"))
        XCTAssertEqual(spooky, .playlist(pumpkins))
    }

    func testTheSeasonsMixesAndOtherHolidaysByName() async {
        let halloween = await resolve(MediaRequest(name: "the Halloween mix"))
        XCTAssertEqual(halloween?.title, "Halloween Mix")
        let fall = await resolve(MediaRequest(name: "fall mix"))
        XCTAssertEqual(fall?.title, "Fall Mix")
        let christmas = await resolve(MediaRequest(name: "Christmas music"))
        XCTAssertEqual(christmas?.title, "Holiday Mix", "out of season, on request")
        let genre = await resolve(MediaRequest(genres: ["Christmas"]))
        XCTAssertEqual(genre?.title, "Holiday Mix")
        if case .mix(_, let theme)? = christmas {
            XCTAssertEqual(theme.moment, .christmas, "built from the holidays' moods")
        } else {
            XCTFail("Christmas music should be the Holiday Mix")
        }
    }

    func testArtistsAndAlbumsFromTheLibrarysLists() async {
        let catalog = catalog()
        let artist = await resolve(MediaRequest(name: "velvet static"), in: catalog)
        XCTAssertEqual(artist, .artist(velvet))
        let accented = await resolve(MediaRequest(kind: .artist, name: "Ana Rios"), in: catalog)
        XCTAssertEqual(accented, .artist(ana))
        let album = await resolve(MediaRequest(kind: .album, name: "Night Swimming"), in: catalog)
        XCTAssertEqual(album, .album(nightSwimming, startAt: nil, shuffled: false))
        let byArtist = await resolve(MediaRequest(kind: .any, artist: "Northern Lights Society", album: "Aurora"), in: catalog)
        XCTAssertEqual(byArtist, .album(aurora, startAt: nil, shuffled: false))
        XCTAssertTrue(catalog.searches.isEmpty, "exact matches in the saved lists don't ask the server")
    }

    func testSongsComeFromTheServersSearchAndPlayOnIntoTheirAlbum() async {
        let catalog = catalog()
        let waltz = Track(id: "t9", title: "Ember Waltz", artist: "Saint Ember", album: "Bonfire Hymns", albumID: "b9")
        let cover = Track(id: "t11", title: "Ember Waltz", artist: "Somebody Else", album: "Covers", albumID: "b11")
        catalog.results = SearchResults(artists: [], albums: [], tracks: [cover, waltz])
        let plan = await resolve(MediaRequest(kind: .song, name: "Ember Waltz", artist: "Saint Ember"), in: catalog)
        XCTAssertEqual(plan, .album(Album(id: "b9", title: "Bonfire Hymns", artist: "Saint Ember"), startAt: "t9", shuffled: false))
        XCTAssertEqual(catalog.searches, ["Ember Waltz"])

        let nobody = await resolve(MediaRequest(kind: .song, name: "Ember Waltz", artist: "Nobody"), in: catalog)
        XCTAssertNil(nobody, "the wrong artist's song isn't played instead")
    }

    func testPodcastsAndAudiobooksAreNotTruffles() async {
        let plan = await resolve(MediaRequest(kind: .unsupported, name: "Road Trip"))
        XCTAssertNil(plan)
        XCTAssertEqual(MediaRequest(INMediaSearch(mediaType: .podcastShow, sortOrder: .unknown, mediaName: "x", artistName: nil, albumName: nil,
                                                  genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil),
                                    shuffled: nil).kind, .unsupported)
    }

    func testSiriKitsSearchBecomesARequest() {
        let search = INMediaSearch(mediaType: .song, sortOrder: .unknown, mediaName: " Ember Waltz ", artistName: "Saint Ember", albumName: "",
                                   genreNames: ["Folk"], moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil)
        let request = MediaRequest(search, shuffled: true)
        XCTAssertEqual(request, MediaRequest(kind: .song, name: "Ember Waltz", artist: "Saint Ember", album: nil, genres: ["Folk"], shuffled: true))
        XCTAssertTrue(MediaRequest(nil, shuffled: nil).isOpenEnded)
    }

    func testPicksCarryWhatHandleNeeds() {
        XCTAssertEqual(SiriPick(.playlist(roadTrip)).identifier, "truffle:playlist:p1")
        XCTAssertEqual(SiriPick(.artist(velvet)).type, .artist)
        let song = SiriPick(.album(nightSwimming, startAt: "t1", shuffled: false))
        XCTAssertEqual(song.type, .song)
        XCTAssertEqual(song.artist, "Velvet Static")
        XCTAssertNotEqual(song.identifier, SiriPick(.album(nightSwimming, startAt: nil, shuffled: false)).identifier)
        let picks = mixes(date(2026, 10, 31)).map { SiriPick(.mix($0.mix, theme: $0.theme)).identifier }
        XCTAssertEqual(Set(picks).count, picks.count, "Halloween's mix and the Holiday Mix are both moments, but not the same pick")
    }
}
