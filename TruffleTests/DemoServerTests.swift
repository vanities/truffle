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
        XCTAssertEqual(library.tracks.count, 148)
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
        XCTAssertEqual(page["totalSize"] as? Int, 148)

        // Truffle encodes comparison filters into the name: userRating%3E=8.
        let liked = try await json("/library/sections/1/all?type=10&userRating%3E=8")
        XCTAssertEqual(liked["totalSize"] as? Int, 22, "every seventh song is loved")

        let albums = try await json("/library/sections/1/all?type=9")
        XCTAssertEqual(albums["totalSize"] as? Int, 22)

        // Home's Recently Played shelf.
        let played = try await json("/library/sections/1/all?type=9&sort=lastViewedAt:desc&X-Plex-Container-Size=30")
        let stamps = ((played["Metadata"] as? [[String: Any]]) ?? []).compactMap { $0["lastViewedAt"] as? Int }
        XCTAssertFalse(stamps.isEmpty)
        XCTAssertEqual(stamps, stamps.sorted(by: >), "newest first")
        XCTAssertGreaterThan(stamps[0], Int(Date().timeIntervalSince1970) - 7 * 86_400, "something played this week")
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

    // MARK: - Helpers

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
