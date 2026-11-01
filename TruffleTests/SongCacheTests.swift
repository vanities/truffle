import XCTest
@testable import Truffle

/// Songs saved on the phone for the car: how they're named and which go when the cache is full.
final class SongCacheTests: XCTestCase {
    private func track(_ id: String, partKey: String?) -> Track {
        Track(id: id, title: "Song", artist: "A", album: "B", partKey: partKey, codec: "flac")
    }

    func testNameKeepsTheFilesExtensionForAVFoundation() throws {
        let name = try XCTUnwrap(SongCache.fileName(for: track("4521", partKey: "/library/parts/88/1698000000/file.flac")))
        XCTAssertTrue(name.hasPrefix("4521-"), name)
        XCTAssertTrue(name.hasSuffix(".flac"), name)
        let mp3 = try XCTUnwrap(SongCache.fileName(for: track("7", partKey: "/library/parts/9/1/file.MP3")))
        XCTAssertTrue(mp3.hasSuffix(".mp3"), mp3)
    }

    func testAReplacedFileOnTheServerIsANewName() {
        let before = SongCache.fileName(for: track("4521", partKey: "/library/parts/88/1698000000/file.flac"))
        let after = SongCache.fileName(for: track("4521", partKey: "/library/parts/91/1700000000/file.flac"))
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before, SongCache.fileName(for: track("4521", partKey: "/library/parts/88/1698000000/file.flac")), "stable")
    }

    func testNoFileOnTheServerMeansNothingToSave() {
        XCTAssertNil(SongCache.fileName(for: track("1", partKey: nil)))
        XCTAssertNil(SongCache.fileName(for: track("1", partKey: "")))
    }

    func testNameUsesTheCodecWhenThePathHasNoExtension() {
        XCTAssertEqual(SongCache.fileName(for: track("1", partKey: "/library/parts/1/2/file"))?.hasSuffix(".flac"), true)
    }

    func testFullCacheDropsTheLeastRecentlyPlayedButNeverWhatsComingUp() {
        let day: TimeInterval = 86_400
        let files = [
            SongCache.CachedFile(name: "oldest", bytes: 40, used: Date(timeIntervalSince1970: 0)),
            SongCache.CachedFile(name: "coming-up", bytes: 40, used: Date(timeIntervalSince1970: day)),
            SongCache.CachedFile(name: "older", bytes: 40, used: Date(timeIntervalSince1970: 2 * day)),
            SongCache.CachedFile(name: "newest", bytes: 40, used: Date(timeIntervalSince1970: 3 * day)),
        ]
        XCTAssertEqual(SongCache.evictions(files, budget: 100, pinned: ["coming-up"]), ["oldest", "older"])
        XCTAssertEqual(SongCache.evictions(files, budget: 160, pinned: []), [], "fits")
        XCTAssertEqual(SongCache.evictions(files, budget: 0, pinned: ["coming-up"]), ["oldest", "older", "newest"])
    }
}
