import XCTest
@testable import Truffle

/// The cover on top of an album or playlist.
final class HeaderCoverTests: XCTestCase {
    func testItTakesMostOfAPhonesWidthAndStopsGrowingOnAnIPad() {
        XCTAssertEqual(HeaderCover.side(pageWidth: 402, compactHeight: false), 289, "6.3\" phone")
        XCTAssertEqual(HeaderCover.side(pageWidth: 440, compactHeight: false), 317, "6.9\" phone")
        XCTAssertEqual(HeaderCover.side(pageWidth: 1032, compactHeight: false), 340, "13\" iPad")
    }

    func testAPhoneOnItsSideKeepsRoomForTheSongs() {
        XCTAssertEqual(HeaderCover.side(pageWidth: 874, compactHeight: true), 250)
    }

    func testBeforeThePageIsMeasuredItIsTheOldSize() {
        XCTAssertEqual(HeaderCover.side(pageWidth: 0, compactHeight: false), 250)
    }
}
