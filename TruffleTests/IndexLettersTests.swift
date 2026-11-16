import XCTest
@testable import Truffle

/// The A to Z index down the side of Artists and Albums.
final class IndexLettersTests: XCTestCase {
    func testANameIsFiledUnderItsFirstLetterWithoutAccents() {
        XCTAssertEqual(IndexLetters.letter(for: "bonobo"), "B")
        XCTAssertEqual(IndexLetters.letter(for: "Édith Piaf"), "E")
        XCTAssertEqual(IndexLetters.letter(for: "  Ólafur Arnalds"), "O")
        for name in ["20syl", "¥$", "王若琳", "$oul $old $eparately", ""] {
            XCTAssertEqual(IndexLetters.letter(for: name), "#", name)
        }
    }

    func testEachLetterStopsAtTheFirstNameUnderIt() {
        let names = fill(["20syl", "Air", "Autechre", "Bonobo", "Clams Casino", "Four Tet"])
        let marks = IndexLetters.marks(for: names, id: { $0 }, name: { $0 })
        XCTAssertEqual(marks.map(\.letter), ["#", "A", "B", "C", "F", "Z"])
        XCTAssertEqual(marks.map(\.id), ["20syl", "Air", "Bonobo", "Clams Casino", "Four Tet", "Zed 0"])
    }

    func testPlexsOrderIsNotStrictlyByFirstLetter() {
        // As Adam's library sorts: "$oul…" among the S's, a second run of S, other scripts after Z.
        let names = fill(["11:11", "Sade", "$oul $old $eparately", "Slowdive", "Tycho", "Sufjan Stevens"]) + ["王若琳", "関戸剛"]
        let marks = IndexLetters.marks(for: names, id: { $0 }, name: { $0 })
        XCTAssertEqual(marks.map(\.letter), ["#", "S", "T", "Z", "#"], "numbers on top, other scripts at the bottom, no stray stops")
        XCTAssertEqual(marks.last?.id, "王若琳")
        XCTAssertEqual(marks[1].id, "Sade")
    }

    func testAShortListOrOneLetterHasNoIndex() {
        XCTAssertEqual(IndexLetters.marks(for: ["Air", "Bonobo", "Caribou"], id: { $0 }, name: { $0 }), [])
        let allA = (0..<60).map { "Artist \($0)" }
        XCTAssertEqual(IndexLetters.marks(for: allA, id: { $0 }, name: { $0 }), [])
    }

    /// Pads a list with Z's up to the length that earns an index.
    private func fill(_ names: [String]) -> [String] {
        names + (0..<IndexLetters.minimumItems).map { "Zed \($0)" }
    }
}
