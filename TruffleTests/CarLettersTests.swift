import CarPlay
import XCTest
@testable import Truffle

final class CarLettersTests: XCTestCase {
    private func artist(_ title: String, sort: String? = nil) -> Artist {
        Artist(id: title, title: title, sortTitle: sort)
    }

    func testArtistsAreFiledByLetterWithNumbersAndOtherScriptsLast() {
        let groups = CarLetters.groups([artist("2Pac"), artist("Air"), artist("Autechre"), artist("The Lumineers", sort: "Lumineers"),
                                        artist("Édith Piaf"), artist("王若琳"), artist("Bonobo")])
        XCTAssertEqual(groups.map(\.letter), ["A", "B", "E", "L", "#"])
        XCTAssertEqual(groups[0].artists.map(\.title), ["Air", "Autechre"], "the library's order inside a letter")
        XCTAssertEqual(groups[3].artists.map(\.title), ["The Lumineers"], "by Plex's sort name")
        XCTAssertEqual(groups[4].artists.map(\.title), ["2Pac", "王若琳"])
        XCTAssertEqual(groups.flatMap(\.artists).count, 7, "every artist is under exactly one letter")
    }

    func testLettersSplitEvenlyIntoAsFewRowsAsCarPlayAllows() {
        let groups = (0..<27).map { CarLetters.Group(letter: "\($0)", artists: []) }
        XCTAssertEqual(CarLetters.rows(groups, atMost: 24).map(\.count), [14, 13], "not 24 and a stub of 3")
        XCTAssertEqual(CarLetters.rows(groups, atMost: 30).map(\.count), [27])
        XCTAssertEqual(CarLetters.rows(groups, atMost: 8).map(\.count), [7, 7, 7, 6])
        XCTAssertEqual(CarLetters.rows(groups, atMost: 0).count, 27, "never a row of nothing")
        XCTAssertEqual(CarLetters.rows(groups, atMost: 24).flatMap { $0 }, groups, "every letter, in order")
        XCTAssertTrue(CarLetters.rows([], atMost: 24).isEmpty)
    }

    /// CarPlay's own pieces, as far as they can be checked without a car: a row holds at least a few tiles,
    /// and a row of tiles with no title can be made.
    @MainActor
    func testARowOfTilesCanBeBuilt() {
        XCTAssertGreaterThanOrEqual(CPMaximumNumberOfGridImages, 4)
        let size = CPListImageRowItemGridElement.maximumImageSize
        print("[carletters] CarPlay shows \(CPMaximumNumberOfGridImages) images a row, at most \(size.width)x\(size.height) pt")
        let elements = ["A", "B", "#"].map { CPListImageRowItemGridElement(image: CarLetters.tile($0, size: size, scale: 2, color: .systemTeal)) }
        let row = CPListImageRowItem(text: nil, gridElements: elements, allowsMultipleLines: true)
        XCTAssertEqual(row.elements.count, 3)
        XCTAssertNil(row.text)
        XCTAssertTrue(row.allowsMultipleLines)
    }

    func testATileIsDrawnAtTheCarsScale() {
        let tile = CarLetters.tile("W", size: CGSize(width: 60, height: 44), scale: 3, color: .systemOrange)
        XCTAssertEqual(tile.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(CarLetters.tile("W", size: CGSize(width: 220, height: 220), scale: 3, color: .systemOrange).size,
                       CGSize(width: 96, height: 96), "not CarPlay's 220 pt maximum")
        XCTAssertEqual(tile.scale, 3)
        XCTAssertNotNil(tile.cgImage)
    }
}
