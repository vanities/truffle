import XCTest
@testable import Truffle

/// Shapes copied from a real PMS 1.43 server (titles invented).
final class PlexDecodingTests: XCTestCase {
    private func container(_ json: String) throws -> PlexContainer {
        try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: Data(json.utf8)).container
    }

    func testTrackDetailsCarryLoudnessSentAsStrings() throws {
        let json = """
        {"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"25321","type":"track","title":"Epilogue 1",
        "grandparentTitle":"Konami Kukeiha Club","parentTitle":"Castlevania Collection","parentRatingKey":"25309",
        "grandparentRatingKey":"25300","index":2,"parentIndex":1,"duration":81560,"parentThumb":"/library/metadata/25309/thumb/1783937765",
        "parentYear":1990,"userRating":10.0,"Mood":[{"tag":"Eerie"}],
        "Media":[{"container":"flac","audioCodec":"flac","bitrate":843,"Part":[{"key":"/library/parts/25958/1680402005/file.flac",
        "container":"flac","size":8602142,"Stream":[{"streamType":2,"albumGain":"-11.79","gain":"-11.79","loudness":"-12.74","peak":"0.827637"}]}]}]}]}}
        """
        let track = try XCTUnwrap(Track(try container(json).metadata[0]))
        XCTAssertEqual(track.id, "25321")
        XCTAssertEqual(track.artist, "Konami Kukeiha Club")
        XCTAssertEqual(track.album, "Castlevania Collection")
        XCTAssertEqual(track.duration, 81.56, accuracy: 0.001)
        XCTAssertEqual(track.partKey, "/library/parts/25958/1680402005/file.flac")
        XCTAssertEqual(track.thumb, "/library/metadata/25309/thumb/1783937765")
        XCTAssertEqual(track.codec, "flac")
        XCTAssertEqual(track.loudness, -12.74)
        XCTAssertEqual(track.gain, -11.79)
        XCTAssertTrue(track.isLiked)
        XCTAssertEqual(track.year, 1990)
    }

    func testCompilationTracksUseTheirOwnArtist() throws {
        let json = """
        {"MediaContainer":{"Metadata":[{"ratingKey":"1","type":"track","title":"Song","originalTitle":"Guest Artist",
        "grandparentTitle":"Various Artists","parentTitle":"Hits"}]}}
        """
        XCTAssertEqual(Track(try container(json).metadata[0])?.artist, "Guest Artist")
    }

    func testHistoryEntriesWithStringSectionIDs() throws {
        let json = """
        {"MediaContainer":{"size":1,"Metadata":[{"historyKey":"/status/sessions/history/13533","key":"/library/metadata/26827",
        "ratingKey":"26827","librarySectionID":"3","title":"Rose of May","type":"track","viewedAt":1793399270,"accountID":1,"deviceID":31}]}}
        """
        let entry = try container(json).metadata[0]
        XCTAssertEqual(entry.ratingKey, "26827")
        XCTAssertEqual(entry.librarySectionID, "3")
        XCTAssertEqual(entry.viewedAt, 1_793_399_270)
    }

    func testOneOddItemDoesNotLoseTheRest() throws {
        let json = """
        {"MediaContainer":{"totalSize":17085,"Metadata":[{"ratingKey":"1","type":"track","title":"Good"},"not an object",
        {"ratingKey":"2","type":"track","title":"Also good"}]}}
        """
        let decoded = try container(json)
        XCTAssertEqual(decoded.totalSize, 17085)
        XCTAssertEqual(decoded.metadata.map(\.ratingKey), ["1", "2"])
    }

    func testPlaylistsAndSections() throws {
        let playlists = try container("""
        {"MediaContainer":{"size":2,"Metadata":[{"ratingKey":"901","title":"All Music","smart":true,"leafCount":16838,"duration":3600000,
        "composite":"/playlists/901/composite/1"},{"ratingKey":"902","title":"Road Trip","smart":false,"leafCount":41}]}}
        """).metadata.compactMap(Playlist.init)
        XCTAssertEqual(playlists.map(\.title), ["All Music", "Road Trip"])
        XCTAssertTrue(playlists[0].isSmart && playlists[0].isLarge)
        XCTAssertFalse(playlists[1].isSmart)

        let sections = try container("""
        {"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Movies"},{"key":"3","type":"artist","title":"Music"},
        {"key":"4","type":"artist","title":"Books"}]}}
        """).directories.filter { $0.type == "artist" }
        XCTAssertEqual(sections.map(\.key), ["3", "4"])
    }

    func testSkillMadeMixesCarryTheirThemeYearPosterAndBlurb() throws {
        let json = """
        {"MediaContainer":{"Metadata":[{"ratingKey":"55312","title":"🎃 Halloween 2026","smart":false,"leafCount":51,
        "summary":"Spooky, but make it bop. truffle-mix:halloween:2026","thumb":"/library/metadata/55312/thumb/1793408015",
        "composite":"/playlists/55312/composite/1793408015"},{"ratingKey":"7","title":"Road Trip","leafCount":3,
        "composite":"/playlists/7/composite/1"}]}}
        """
        let playlists = try container(json).metadata.compactMap(Playlist.init)
        XCTAssertEqual(playlists[0].mixTag?.theme, "halloween")
        XCTAssertEqual(playlists[0].mixTag?.year, 2026)
        XCTAssertEqual(playlists[0].blurb, "Spooky, but make it bop.")
        XCTAssertEqual(playlists[0].thumb, "/library/metadata/55312/thumb/1793408015", "a custom poster beats the collage")
        XCTAssertNil(playlists[1].mixTag)
        XCTAssertEqual(playlists[1].thumb, "/playlists/7/composite/1")
    }

    func testResourcesBecomeServersWithAPlainHomeAddressToo() throws {
        let json = """
        [{"name":"NAS","provides":"server","clientIdentifier":"abc","owned":true,"accessToken":"t",
          "connections":[{"protocol":"https","address":"192.168.1.10","port":32400,"uri":"https://192-168-1-10.x.plex.direct:32400","local":true,"relay":false},
                         {"protocol":"https","address":"203.0.113.9","port":32400,"uri":"https://203-0-113-9.x.plex.direct:32400","local":false,"relay":false},
                         {"protocol":"https","address":"relay","port":8443,"uri":"https://relay.x.plex.direct:8443","local":false,"relay":true}]},
         {"name":"Phone","provides":"client,player","clientIdentifier":"p","connections":[]}]
        """
        let resources = try JSONDecoder().decode([PlexResource].self, from: Data(json.utf8))
        let servers = resources.compactMap { PlexServerInfo(resource: $0, fallbackToken: "user") }
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].connections.map(\.kind), [.local, .local, .remote, .relay])
        XCTAssertEqual(servers[0].connections[1].uri.absoluteString, "http://192.168.1.10:32400")
    }
}
