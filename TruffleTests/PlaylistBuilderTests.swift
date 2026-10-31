import ImageIO
import UIKit
import XCTest
@testable import Truffle

/// The playlist editor's pieces: the move planner, the cover, the request that carries it, the sort
/// orders, and a whole create-then-edit round trip through the in-app demo server.
final class PlaylistBuilderTests: XCTestCase {
    // MARK: - Moves

    func testMovesPutEverySlotInPlaceWithTheFewestCalls() {
        var generator = SeededGenerator(seed: 7)
        for size in [0, 1, 2, 5, 12, 40] {
            for _ in 0..<25 {
                let current = Array(100..<(100 + size))
                let desired = current.shuffled(using: &generator)
                let moves = PlaylistReorder.moves(from: current, to: desired)
                var order = current
                for move in moves { PlaylistReorder.apply(move, to: &order) }
                XCTAssertEqual(order, desired, "\(current) → \(desired)")
                let positions = desired.map { current.firstIndex(of: $0) ?? 0 }
                XCTAssertEqual(moves.count, size - PlaylistReorder.longestIncreasing(positions).count, "only slots out of the longest run move")
            }
        }
    }

    func testTopSongToTheBottomIsOneMove() {
        let moves = PlaylistReorder.moves(from: [1, 2, 3, 4], to: [2, 3, 4, 1])
        XCTAssertEqual(moves, [.init(itemID: 1, after: 4)])
        XCTAssertEqual(PlaylistReorder.moves(from: [1, 2, 3], to: [3, 1, 2]), [.init(itemID: 3, after: nil)], "nil after: to the top")
        XCTAssertEqual(PlaylistReorder.moves(from: [1, 2, 3], to: [1, 2, 3]), [])
    }

    func testSlotsMissingOnTheServerAreSkipped() {
        // Someone removed 2 elsewhere; the plan still orders what's there.
        var order = [1, 3, 4]
        for move in PlaylistReorder.moves(from: order, to: [4, 2, 1, 3]) { PlaylistReorder.apply(move, to: &order) }
        XCTAssertEqual(order, [4, 1, 3])
    }

    // MARK: - Draft

    func testDraftNeedsANameAndANewOneNeedsSongs() {
        var draft = PlaylistDraft.new()
        XCTAssertFalse(draft.canSave)
        draft.title = "   "
        draft.songs = [.init(track: Self.track("1"))]
        XCTAssertFalse(draft.canSave, "a blank name doesn't count")
        draft.title = " Night Drive "
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.trimmedTitle, "Night Drive")
        var edit = PlaylistDraft.editing(Playlist(id: "9", title: "Old", isSmart: false, trackCount: 0))
        edit.songs = []
        XCTAssertTrue(edit.canSave, "yours can be emptied")
    }

    func testEditingAMixKeepsItsTag() {
        let mix = Playlist(id: "901", title: "🎃 Halloween 2026", isSmart: false, trackCount: 12,
                           summary: "Spooky season. truffle-mix:halloween:2026")
        var draft = PlaylistDraft.editing(mix)
        XCTAssertEqual(draft.summary, "Spooky season.", "the tag isn't shown")
        draft.summary = "Boo."
        XCTAssertEqual(draft.summaryToSave, "Boo. truffle-mix:halloween:2026")
        draft.summary = ""
        XCTAssertEqual(draft.summaryToSave, "truffle-mix:halloween:2026")
        XCTAssertEqual(PlaylistDraft.new().summaryToSave, "")
    }

    // MARK: - Cover

    func testCoverIsTheMiddleSquareAtAThousandPixels() throws {
        // Red, green, blue thirds: the middle square keeps all of green and a sliver of each side.
        let jpeg = try XCTUnwrap(CoverImage.squareJPEG(from: Self.stripes(width: 2400, height: 1600)))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG")
        let image = try XCTUnwrap(Self.decode(jpeg))
        XCTAssertEqual(image.width, 1000)
        XCTAssertEqual(image.height, 1000)
        let pixels = Self.rgb(image)
        XCTAssertGreaterThan(pixels(125, 500).r, 200, "left: red")
        XCTAssertGreaterThan(pixels(500, 500).g, 200, "middle: green")
        XCTAssertGreaterThan(pixels(875, 500).b, 200, "right: blue")
    }

    func testSmallPhotosAreSquaredNotBlownUp() throws {
        let image = try XCTUnwrap(CoverImage.squareJPEG(from: Self.stripes(width: 300, height: 500)).flatMap(Self.decode))
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 300)
        XCTAssertNil(CoverImage.squareJPEG(from: Data("not an image".utf8)))
    }

    func testCoverUploadCarriesTheJPEGAsTheBody() {
        let client = PlexClient(endpoint: PlexEndpoint(baseURL: URL(string: "http://10.0.0.2:32400")!, kind: .local, machineIdentifier: "m", token: "t"),
                                identity: PlexIdentity(clientIdentifier: "c", version: "1", platformVersion: "27", deviceName: "d", model: "iPhone"))
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let request = client.request("POST", "/library/metadata/42/posters", body: jpeg, contentType: "image/jpeg")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, jpeg)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(request.url?.path(), "/library/metadata/42/posters")
        XCTAssertNil(client.request("PUT", "/playlists/42").httpBody)
    }

    // MARK: - Sorts

    func testEachListDefaultsToItsFirstOrder() {
        XCTAssertEqual(LikedSort.standard, .recentlyLiked)
        XCTAssertEqual(AlbumSort.standard, .title)
        XCTAssertEqual(ArtistSort.standard, .name)
        XCTAssertEqual(PlaylistSort.standard, .title)
        XCTAssertEqual(PlaylistSongSort.standard, .playlistOrder)
        XCTAssertEqual(Set([LikedSort.defaultsKey, AlbumSort.defaultsKey, ArtistSort.defaultsKey, PlaylistSort.defaultsKey,
                            PlaylistSongSort.defaultsKey]).count, 5, "each list remembers its own")
    }

    func testLikedAsksPlexToSort() {
        XCTAssertEqual(LikedSort.allCases.map(\.plexSort), ["lastRatedAt:desc", "titleSort", "artist.titleSort", "album.titleSort",
                                                            "addedAt:desc", "viewCount:desc"])
    }

    func testAlbumsSortOnThePhone() {
        let day: TimeInterval = 86_400
        let albums = [
            Album(id: "1", title: "Aurora", artist: "The Lanterns", year: 2019, addedAt: Date(timeIntervalSince1970: 5 * day)),
            Album(id: "2", title: "Bonfire", artist: "Cold Coast", year: 2023, addedAt: Date(timeIntervalSince1970: 9 * day),
                  lastViewedAt: Date(timeIntervalSince1970: 3 * day)),
            Album(id: "3", title: "Candle", artist: "Lanterns, The", year: nil, lastViewedAt: Date(timeIntervalSince1970: 7 * day)),
            Album(id: "4", title: "Drift", artist: "Cold Coast", year: 2020),
        ]
        XCTAssertEqual(AlbumSort.title.sorted(albums).map(\.id), ["1", "2", "3", "4"], "Plex's own title order, untouched")
        XCTAssertEqual(AlbumSort.artist.sorted(albums).map(\.id), ["4", "2", "1", "3"], "\"The \" skipped; by year within an artist")
        XCTAssertEqual(AlbumSort.year.sorted(albums).map(\.id), ["2", "4", "1", "3"], "newest first, no year last")
        XCTAssertEqual(AlbumSort.recentlyAdded.sorted(albums).map(\.id), ["2", "1", "3", "4"])
        XCTAssertEqual(AlbumSort.recentlyPlayed.sorted(albums).map(\.id), ["3", "2", "1", "4"], "never played last, in title order")
    }

    func testArtistsPlaylistsAndPlaylistSongsSortOnThePhone() {
        let artists = [Artist(id: "a", title: "Arcade", viewCount: 3, lastViewedAt: Date(timeIntervalSince1970: 50)),
                       Artist(id: "b", title: "Bells", viewCount: 40, lastViewedAt: Date(timeIntervalSince1970: 10)),
                       Artist(id: "c", title: "Coast")]
        XCTAssertEqual(ArtistSort.name.sorted(artists).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ArtistSort.mostPlayed.sorted(artists).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(ArtistSort.recentlyPlayed.sorted(artists).map(\.id), ["a", "b", "c"])

        let playlists = [Playlist(id: "1", title: "road trip", isSmart: false, trackCount: 20, updatedAt: Date(timeIntervalSince1970: 100)),
                         Playlist(id: "2", title: "All Music", isSmart: true, trackCount: 148),
                         Playlist(id: "3", title: "Late Night", isSmart: false, trackCount: 9, updatedAt: Date(timeIntervalSince1970: 900))]
        XCTAssertEqual(PlaylistSort.title.sorted(playlists).map(\.id), ["2", "3", "1"], "case doesn't matter")
        XCTAssertEqual(PlaylistSort.recentlyUpdated.sorted(playlists).map(\.id), ["3", "1", "2"])
        XCTAssertEqual(PlaylistSort.mostSongs.sorted(playlists).map(\.id), ["2", "1", "3"])

        let songs = [Self.track("1", title: "Zephyr", artist: "Bells", album: "Night", number: 2),
                     Self.track("2", title: "Amber", artist: "The Arcade", album: "Prize", number: 1),
                     Self.track("3", title: "Moth", artist: "Bells", album: "Night", number: 1),
                     Self.track("4", title: "Bloom", artist: "Bells", album: "Day", number: 5)]
        XCTAssertEqual(PlaylistSongSort.playlistOrder.sorted(songs).map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(PlaylistSongSort.title.sorted(songs).map(\.id), ["2", "4", "3", "1"])
        XCTAssertEqual(PlaylistSongSort.artist.sorted(songs).map(\.id), ["2", "4", "3", "1"], "artist, album, then track number")
        XCTAssertEqual(PlaylistSongSort.album.sorted(songs).map(\.id), ["4", "3", "1", "2"])
    }

    func testPlaylistsAndArtistsDecodeWhatTheSortsRead() throws {
        let json = """
        {"MediaContainer":{"size":2,"Metadata":[
        {"ratingKey":"77","type":"playlist","title":"Road Trip","smart":false,"leafCount":3,"updatedAt":1780000123,
         "thumb":"/library/metadata/77/thumb/1780000123","summary":"Windows down."},
        {"ratingKey":"1001","type":"artist","title":"The Lanterns","viewCount":41,"lastViewedAt":1780000500}]}}
        """
        let metadata = try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: Data(json.utf8)).container.metadata
        let playlist = try XCTUnwrap(Playlist(metadata[0]))
        XCTAssertEqual(playlist.updatedAt, Date(timeIntervalSince1970: 1_780_000_123))
        XCTAssertEqual(playlist.thumb, "/library/metadata/77/thumb/1780000123")
        let artist = try XCTUnwrap(Artist(metadata[1]))
        XCTAssertEqual(artist.viewCount, 41)
        XCTAssertEqual(artist.lastViewedAt, Date(timeIntervalSince1970: 1_780_000_500))
    }

    func testOldSnapshotsStillLoad() throws {
        // Saved before artists had plays and playlists had updatedAt.
        let json = #"{"id":"1001","title":"The Lanterns","albumCount":2}"#
        let artist = try JSONDecoder().decode(Artist.self, from: Data(json.utf8))
        XCTAssertNil(artist.viewCount)
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(#"{"id":"9","title":"Old","isSmart":false,"trackCount":3,"duration":0}"#.utf8))
        XCTAssertNil(playlist.updatedAt)
    }

    // MARK: - Round trip

    /// Create a playlist the way Save does (songs in order, description, cover), then edit it (rename,
    /// drop a song, add two, reorder), all through MusicLibrary against the in-app demo server.
    @MainActor
    func testSaveMakesThenEditsAPlaylistOnTheDemo() async throws {
        let suite = "truffle.tests.playlist-builder"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let library = MusicLibrary(identity: PlexIdentity(clientIdentifier: "tests", version: "1", platformVersion: "27", deviceName: "d", model: "iPhone"),
                                   settings: AppSettings(defaults: defaults),
                                   store: LibraryStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                   keychain: Keychain(service: "com.vanities.truffle.tests"))
        // startDemo() remembers the demo for the next launch; put that back as it was.
        let wasDemo = UserDefaults.standard.bool(forKey: "demo.active")
        addTeardownBlock {
            if wasDemo { UserDefaults.standard.set(true, forKey: "demo.active") } else { UserDefaults.standard.removeObject(forKey: "demo.active") }
            await DemoServer.shared.stop()
        }
        library.startDemo()
        for _ in 0..<300 where library.phase != .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(library.phase, .ready)

        let liked = try await library.likedTracks()
        XCTAssertGreaterThanOrEqual(liked.count, 5)
        var draft = PlaylistDraft.new(with: Array(liked.prefix(3)))
        draft.title = "  Night Drive "
        draft.summary = "Windows down."
        draft.cover = CoverImage.squareJPEG(from: Self.stripes(width: 1600, height: 900))
        let made = try await library.save(draft)
        XCTAssertEqual(made.missed, [])
        XCTAssertEqual(made.playlist.title, "Night Drive")
        XCTAssertEqual(made.playlist.summary, "Windows down.")
        XCTAssertEqual(made.playlist.trackCount, 3)
        XCTAssertTrue(library.playlists.contains { $0.id == made.playlist.id }, "playlists refreshed")
        let thumb = try XCTUnwrap(made.playlist.thumb)
        XCTAssertTrue(thumb.hasPrefix("/library/metadata/\(made.playlist.id)/thumb/"), "the uploaded cover, not the collage: \(thumb)")
        let client = try XCTUnwrap(library.client)
        let (art, _) = try await URLSession.shared.data(from: client.artworkURL(thumb, size: 300))
        XCTAssertEqual(art, draft.cover, "the cover comes back as uploaded")
        let entries = try await library.playlistEntries(of: made.playlist.id)
        XCTAssertEqual(entries.map(\.track.id), draft.songs.map(\.track.id), "songs in the picked order")

        let before = entries.map { PlaylistDraft.Song(track: $0.track, itemID: $0.itemID) }
        let more = liked.dropFirst(3).prefix(2).map { PlaylistDraft.Song(track: $0) }
        var edit = PlaylistDraft.editing(made.playlist)
        edit.title = "Night Drive II"
        edit.songs = [more[1], before[0], before[2], more[0]]
        let revision = library.playlistRevisions[made.playlist.id] ?? 0
        let saved = try await library.save(edit, replacing: before)
        XCTAssertEqual(saved.playlist.title, "Night Drive II")
        XCTAssertEqual(saved.playlist.summary, "Windows down.", "untouched")
        XCTAssertEqual(saved.playlist.trackCount, 4)
        XCTAssertGreaterThan(library.playlistRevisions[made.playlist.id] ?? 0, revision, "an open playlist screen reloads")
        let after = try await library.playlistEntries(of: made.playlist.id)
        XCTAssertEqual(after.map(\.track.id), edit.songs.map(\.track.id))
        XCTAssertEqual(after[1].itemID, before[0].itemID, "kept songs keep their slots")
        XCTAssertEqual(after[2].itemID, before[2].itemID)
    }

    // MARK: - Helpers

    private static func track(_ id: String, title: String = "Song", artist: String = "Artist", album: String = "Album",
                              number: Int? = nil) -> Track {
        Track(id: id, title: title, artist: artist, album: album, trackNumber: number, discNumber: 1)
    }

    private static func stripes(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let third = CGFloat(width) / 3
            for (index, color) in [UIColor.red, .green, .blue].enumerated() {
                color.setFill()
                context.fill(CGRect(x: third * CGFloat(index), y: 0, width: third, height: CGFloat(height)))
            }
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }

    private static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private static func rgb(_ image: CGImage) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return { x, y in
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
        }
    }
}
