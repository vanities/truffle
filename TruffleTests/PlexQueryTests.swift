import XCTest
@testable import Truffle

final class PlexQueryTests: XCTestCase {
    func testComparisonFiltersKeepTheEqualsSignLiteral() {
        // PMS 1.43: `viewedAt%3E=…` works and `viewedAt%3E%3D…` is a 400.
        let query = PlexQuery([("viewedAt>", "1793399270"), ("viewedAt<", "1793999999"), ("userRating>>", "8")])
        XCTAssertEqual(query.encoded, "viewedAt%3E=1793399270&viewedAt%3C=1793999999&userRating%3E%3E=8")
    }

    func testOrListsAndSortDirectionsStayReadable() {
        let query = PlexQuery([("album.mood", "90181,90603"), ("sort", "addedAt:desc")])
        XCTAssertEqual(query.encoded, "album.mood=90181,90603&sort=addedAt:desc")
    }

    func testValuesThatCouldBreakTheQueryAreEscaped() {
        let query = PlexQuery([("query", "AC/DC & friends"), ("url", "/library/metadata/1/thumb/2?x=1")])
        XCTAssertEqual(query.encoded, "query=AC%2FDC%20%26%20friends&url=%2Flibrary%2Fmetadata%2F1%2Fthumb%2F2%3Fx%3D1")
    }

    func testPaging() {
        XCTAssertEqual(PlexQuery().page(start: 40, size: 1).encoded, "X-Plex-Container-Start=40&X-Plex-Container-Size=1")
    }

    func testClientURLsCarryTheTokenOnlyWhenAsked() {
        let client = PlexClient(endpoint: PlexEndpoint(baseURL: URL(string: "https://10-0-0-2.abc.plex.direct:32400/")!, kind: .local,
                                                       machineIdentifier: "m", token: "secret"),
                                identity: PlexIdentity(clientIdentifier: "c", version: "1", platformVersion: "27", deviceName: "d", model: "iPhone"))
        XCTAssertEqual(client.url("/library/sections").absoluteString, "https://10-0-0-2.abc.plex.direct:32400/library/sections")
        XCTAssertEqual(client.streamURL(partKey: "/library/parts/9/1/file.flac").absoluteString,
                       "https://10-0-0-2.abc.plex.direct:32400/library/parts/9/1/file.flac?X-Plex-Token=secret")
        XCTAssertTrue(client.artworkURL("/library/metadata/5/thumb/7", size: 300).absoluteString
            .hasSuffix("/photo/:/transcode?width=300&height=300&minSize=1&upscale=1&url=%2Flibrary%2Fmetadata%2F5%2Fthumb%2F7&X-Plex-Token=secret"))
    }
}
