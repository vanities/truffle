import XCTest
@testable import Truffle

/// "Play in the Car": what happens when CarPlay connects. The CarPlay simulator window can't be
/// scripted, so the rule is tested here and every decision is logged.
final class CarAutoplayTests: XCTestCase {
    private let idle = CarAutoplay.Situation(enabled: true, signedIn: true, truffleBusy: false, otherAudio: false, canResume: true)

    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { Track(id: "\($0)", title: "Song \($0)", artist: "A", album: "B") }
    }

    func testPicksUpWhereYouLeftOff() {
        XCTAssertEqual(CarAutoplay.decision(for: idle, alreadyDecided: false), .resume)
    }

    func testShufflesAllWhenTheresNothingToPickUp() {
        var empty = idle
        empty.canResume = false
        XCTAssertEqual(CarAutoplay.decision(for: empty, alreadyDecided: false), .shuffleAll)
    }

    func testNeverTalksOverSomethingPlaying() {
        var truffle = idle
        truffle.truffleBusy = true
        XCTAssertEqual(CarAutoplay.decision(for: truffle, alreadyDecided: false), .busy)
        var podcast = idle
        podcast.otherAudio = true
        XCTAssertEqual(CarAutoplay.decision(for: podcast, alreadyDecided: false), .otherAudio)
        XCTAssertFalse(CarAutoplay.Decision.busy.plays)
        XCTAssertFalse(CarAutoplay.Decision.otherAudio.plays)
    }

    func testOffOrSignedOutStaysQuiet() {
        var off = idle
        off.enabled = false
        XCTAssertEqual(CarAutoplay.decision(for: off, alreadyDecided: false), .off)
        var signedOut = idle
        signedOut.signedIn = false
        signedOut.canResume = false
        XCTAssertEqual(CarAutoplay.decision(for: signedOut, alreadyDecided: false), .signedOut)
    }

    func testOneConnectionStartsOnce() {
        var autoplay = CarAutoplay()
        XCTAssertEqual(autoplay.carConnected(idle), .resume)
        XCTAssertEqual(autoplay.carConnected(idle), .alreadyDecided, "the same connection announced twice")
        autoplay.carDisconnected()
        var playing = idle
        playing.truffleBusy = true
        XCTAssertEqual(autoplay.carConnected(playing), .busy, "the next connection decides again, and Truffle's playing")
        XCTAssertEqual(autoplay.carConnected(idle), .alreadyDecided, "a quiet connection stays quiet when asked again")
    }

    func testWhatCountsAsSomethingToPickUp() {
        var queue = PlayQueue()
        XCTAssertFalse(CarAutoplay.canResume(queue, at: 0, endless: false), "no queue")
        queue.replace(with: tracks(3), startAt: 1)
        XCTAssertTrue(CarAutoplay.canResume(queue, at: 0, endless: false), "more songs after this one")
        queue.move(to: 2)
        XCTAssertTrue(CarAutoplay.canResume(queue, at: 42, endless: false), "the last song, partway through")
        XCTAssertFalse(CarAutoplay.canResume(queue, at: 0, endless: false), "played to its end")
        XCTAssertTrue(CarAutoplay.canResume(queue, at: 0, endless: true), "Shuffle All never ends")
        queue.repeatMode = .all
        XCTAssertTrue(CarAutoplay.canResume(queue, at: 0, endless: false), "repeat goes round again")
    }
}
