import XCTest
@testable import Truffle

/// The in-app demo App Review uses ("Take it for a spin"): bundled assets, Plex-shaped answers over
/// real HTTP, byte ranges for streaming, and the edits Truffle makes.
final class DemoServerTests: XCTestCase {
    private var server: DemoServer!
    private var base: URL!
    private let session = URLSession(configuration: .ephemeral)

    override func setUp() async throws {
        server = DemoServer()
        base = try await server.start()
    }

    override func tearDown() async throws {
        await server.stop()
    }

    func testEveryCoverPortraitPosterAndSongIsBundled() throws {
        let assets = try XCTUnwrap(Bundle.main.url(forResource: "DemoLibrary", withExtension: nil), "DemoLibrary folder in the app")
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "demo-catalog", withExtension: "json"))
        let library = try DemoLibrary(catalogURL: catalog)
        let files = library.albums.map(\.cover) + library.artists.map(\.portrait) + library.playlists.compactMap(\.poster)
            + DemoLibrary.songLengths.indices.map { "audio/song-\($0).m4a" }
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appending(path: file).path), "missing \(file)")
        }
        // 148 songs, plus "A Low Tide Christmas" (6) for holiday music.
        XCTAssertEqual(library.tracks.count, 154)
    }

    func testHistoryRunsUpToNowWithThisWeekInIt() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "demo-catalog", withExtension: "json"))
        let now = Date()
        let history = try DemoLibrary(catalogURL: catalog, now: now).history
        let last = try XCTUnwrap(history.last?.viewedAt)
        XCTAssertGreaterThan(history.count, 800)
        XCTAssertLessThanOrEqual(last, Int(now.timeIntervalSince1970), "no plays in the future")
        XCTAssertGreaterThan(history.filter { $0.viewedAt > Int(now.timeIntervalSince1970) - 7 * 86_400 }.count, 0, "plays this week")
    }

    func testAnswersLikePlex() async throws {
        let identity = try await json("/identity")
        XCTAssertEqual(identity["machineIdentifier"] as? String, DemoLibrary.machineIdentifier)

        let page = try await json("/library/sections/1/all?type=10&sort=id&X-Plex-Container-Start=0&X-Plex-Container-Size=5")
        XCTAssertEqual((page["Metadata"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(page["totalSize"] as? Int, 154)

        // Truffle encodes comparison filters into the name: userRating%3E=8.
        let liked = try await json("/library/sections/1/all?type=10&userRating%3E=8")
        XCTAssertEqual(liked["totalSize"] as? Int, 22, "every seventh song is loved; the holiday album's six stop short of a 23rd")

        let albums = try await json("/library/sections/1/all?type=9")
        XCTAssertEqual(albums["totalSize"] as? Int, 23)

        // Home's Recently Played shelf.
        let played = try await json("/library/sections/1/all?type=9&sort=lastViewedAt:desc&X-Plex-Container-Size=30")
        let stamps = ((played["Metadata"] as? [[String: Any]]) ?? []).compactMap { $0["lastViewedAt"] as? Int }
        XCTAssertFalse(stamps.isEmpty)
        XCTAssertEqual(stamps, stamps.sorted(by: >), "newest first")
        XCTAssertGreaterThan(stamps[0], Int(Date().timeIntervalSince1970) - 7 * 86_400, "something played this week")
    }

    func testTitleSearchMatchesAnyPartOfATitleLikePlex() async throws {
        // Truffle counts holiday music with `title=` searches; PMS reads a plain string filter as
        // "contains", without case.
        let songs = try await json("/library/sections/1/all?type=10&title=SLEIGH&X-Plex-Container-Start=0&X-Plex-Container-Size=500")
        XCTAssertEqual(titles(songs), ["Sleigh Bells on the Boardwalk"])
        let silent = try await json("/library/sections/1/all?type=10&title=silent%20night")
        XCTAssertEqual(titles(silent), ["Silent Night Swim"])
        let albums = try await json("/library/sections/1/all?type=9&title=christmas")
        XCTAssertEqual(titles(albums), ["A Low Tide Christmas"])
        let none = try await json("/library/sections/1/all?type=10&title=rudolph")
        XCTAssertEqual(none["totalSize"] as? Int, 0)
    }

    func testStreamsAudioInByteRanges() async throws {
        var request = URLRequest(url: base.appending(path: "/library/parts/3000/\(DemoLibrary.stamp)/file.m4a"))
        request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data.count, 100)
        XCTAssertTrue(http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-99/") == true)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
    }

    func testPlaylistsAndLikesChangeLikeOnAServer() async throws {
        let uri = "server://x/com.plexapp.plugins.library/library/metadata/3001,3002"
        var create = URLRequest(url: try url("/playlists", ["type": "audio", "title": "Road Snacks", "smart": "0", "uri": uri]))
        create.httpMethod = "POST"
        let made = try await json(create)
        let playlist = try XCTUnwrap((made["Metadata"] as? [[String: Any]])?.first)
        XCTAssertEqual(playlist["leafCount"] as? Int, 2)

        var unlike = URLRequest(url: try url("/:/rate", ["key": "3000", "rating": "-1", "identifier": "com.plexapp.plugins.library"]))
        unlike.httpMethod = "PUT"
        _ = try await session.data(for: unlike)
        let liked = try await json("/library/sections/1/all?type=10&userRating%3E=8")
        XCTAssertEqual(liked["totalSize"] as? Int, 21)
    }

    func testPlaylistEditorCallsWorkLikeOnPlex() async throws {
        let uri = "server://x/com.plexapp.plugins.library/library/metadata/3005,3001,3009"
        let made = try await json(request("POST", "/playlists", ["type": "audio", "title": "Night Drive", "smart": "0", "uri": uri]))
        let playlist = try XCTUnwrap((made["Metadata"] as? [[String: Any]])?.first)
        let id = try XCTUnwrap(playlist["ratingKey"] as? String)
        XCTAssertEqual(playlist["leafCount"] as? Int, 3)
        XCTAssertNotNil(playlist["updatedAt"] as? Int)

        // The description both ways Truffle (and plex_mix.py) sets it, then a new name.
        let (_, described) = try await session.data(for: request("PUT", "/library/metadata/\(id)", ["summary.value": "Windows down.", "summary.locked": "1"]))
        XCTAssertEqual((described as? HTTPURLResponse)?.statusCode, 200)
        _ = try await json(request("PUT", "/playlists/\(id)", ["summary": "Windows down."]))
        _ = try await json(request("PUT", "/playlists/\(id)", ["title": "Night Drive II"]))

        // The cover is the JPEG itself as the body; the playlist's thumb serves it back.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + (0..<90_000).map { UInt8($0 % 251) })
        var upload = try request("POST", "/library/metadata/\(id)/posters", [:])
        upload.httpBody = jpeg
        upload.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, posted) = try await session.data(for: upload)
        XCTAssertEqual((posted as? HTTPURLResponse)?.statusCode, 200)
        let playlists = try await metadata("/playlists?playlistType=audio")
        let saved = try XCTUnwrap(playlists.first { $0["ratingKey"] as? String == id })
        XCTAssertEqual(saved["title"] as? String, "Night Drive II")
        XCTAssertEqual(saved["summary"] as? String, "Windows down.")
        let thumb = try XCTUnwrap(saved["thumb"] as? String)
        let (art, _) = try await session.data(from: url("/photo/:/transcode", ["url": thumb, "width": "300", "height": "300"]))
        XCTAssertEqual(art, jpeg)

        // Slots keep their ids through a removal and moves.
        let slots = try await entries(id)
        XCTAssertEqual(slots.map(\.track), ["3005", "3001", "3009"])
        _ = try await json(request("DELETE", "/playlists/\(id)/items/\(slots[1].item)", [:]))
        _ = try await json(request("PUT", "/playlists/\(id)/items/\(slots[2].item)/move", [:]))
        let moved = try await entries(id)
        XCTAssertEqual(moved.map(\.track), ["3009", "3005"], "no after: to the top")
        XCTAssertEqual(moved.map(\.item), [slots[2].item, slots[0].item])
        _ = try await json(request("PUT", "/playlists/\(id)/items/\(slots[2].item)/move", ["after": String(slots[0].item)]))
        let after = try await entries(id)
        XCTAssertEqual(after.map(\.track), ["3005", "3009"])
        let (_, missing) = try await session.data(for: request("DELETE", "/playlists/\(id)/items/\(slots[1].item)", [:]))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404, "already gone")
    }

    func testSortsAndFieldsTheListsUse() async throws {
        let liked = "/library/sections/1/all?type=10&userRating%3E=8"
        let mostPlayed = try await metadata(liked + "&sort=viewCount:desc").map { $0["viewCount"] as? Int ?? 0 }
        XCTAssertEqual(mostPlayed.count, 22)
        XCTAssertEqual(mostPlayed, mostPlayed.sorted(by: >))
        XCTAssertGreaterThan(mostPlayed[0], mostPlayed[21])

        let byArtist = try await metadata(liked + "&sort=artist.titleSort").compactMap { $0["grandparentTitle"] as? String }
        let artistKeys = byArtist.map { ($0.hasPrefix("The ") ? String($0.dropFirst(4)) : $0).lowercased() }
        XCTAssertEqual(artistKeys, artistKeys.sorted())
        let byAlbum = try await metadata(liked + "&sort=album.titleSort").compactMap { ($0["parentTitle"] as? String)?.lowercased() }
        XCTAssertEqual(byAlbum, byAlbum.sorted())
        let byTitle = try await metadata(liked + "&sort=titleSort").compactMap { ($0["title"] as? String)?.lowercased() }
        XCTAssertEqual(byTitle, byTitle.sorted())
        let added = try await metadata(liked + "&sort=addedAt:desc").compactMap { $0["addedAt"] as? Int }
        XCTAssertEqual(added, added.sorted(by: >))

        // Artists and Playlists sort on the phone, from these fields.
        let artists = try await metadata("/library/sections/1/all?type=8&sort=titleSort")
        XCTAssertTrue(artists.contains { ($0["viewCount"] as? Int ?? 0) > 0 && $0["lastViewedAt"] is Int }, "artists carry plays")
        let playlists = try await metadata("/playlists?playlistType=audio")
        XCTAssertTrue(playlists.allSatisfy { $0["updatedAt"] is Int }, "playlists carry updatedAt")
    }

    // MARK: - Helpers

    private func request(_ method: String, _ path: String, _ query: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: try url(path, query))
        request.httpMethod = method
        return request
    }

    private func metadata(_ pathAndQuery: String) async throws -> [[String: Any]] {
        try await json(pathAndQuery)["Metadata"] as? [[String: Any]] ?? []
    }

    /// (playlistItemID, song id) per slot.
    private func entries(_ playlistID: String) async throws -> [(item: Int, track: String)] {
        try await metadata("/playlists/\(playlistID)/items").compactMap { item in
            guard let slot = item["playlistItemID"] as? Int, let track = item["ratingKey"] as? String else { return nil }
            return (slot, track)
        }
    }

    private func titles(_ container: [String: Any]) -> [String] {
        ((container["Metadata"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }
    }

    private func url(_ path: String, _ query: [String: String]) throws -> URL {
        var components = try XCTUnwrap(URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false))
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try XCTUnwrap(components.url)
    }

    private func json(_ pathAndQuery: String) async throws -> [String: Any] {
        try await json(URLRequest(url: try XCTUnwrap(URL(string: base.absoluteString + pathAndQuery))))
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, request.url?.path ?? "")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["MediaContainer"] as? [String: Any])
    }
}
