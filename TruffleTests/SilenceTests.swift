import XCTest
@testable import Truffle

final class SilenceTests: XCTestCase {
    private let cellular = Silence.Stream(kind: .original, cellular: true)

    func testASongThatStopsMidWayIsWrittenDownSoonerThanASlowStart() {
        XCTAssertTrue(Silence(moment: .midSong(at: 83)).isWorthNoting(lasted: 1.2), "a mid-song stop is heard at once")
        XCTAssertFalse(Silence(moment: .songStart).isWorthNoting(lasted: 1.2), "a skip over cellular takes a moment")
        XCTAssertTrue(Silence(moment: .songStart).isWorthNoting(lasted: 3))
    }

    func testTheLineSaysWhereHowLongWhatItCameFromAndWhatThePlayerDid() {
        var silence = Silence(moment: .midSong(at: 83))
        silence.did("moved to the lighter stream")
        silence.did("moved to the lighter stream")
        silence.did("started with 4 s in hand")
        XCTAssertEqual(silence.line(lasted: 12.4, ending: .sound, song: 9, of: 281, stream: cellular),
                       "Silent 12 s mid-song (1:23 in, song 9 of 281): streaming the original on cellular; moved to the lighter stream; started with 4 s in hand",
                       "a step that repeats is written once")
    }

    func testTheLineTellsAPauseAndAWaitStillGoingFromSoundComingBack() {
        let start = Silence(moment: .songStart)
        XCTAssertEqual(start.line(lasted: 6.04, ending: .paused, song: 10, of: 15, stream: Silence.Stream(kind: .lighter, cellular: true)),
                       "Silent 6.0 s starting song 10 of 15, then paused: streaming the lighter stream on cellular")
        XCTAssertEqual(start.line(lasted: 30, ending: .stillWaiting, song: 10, of: 15, stream: Silence.Stream(kind: .nothingLoaded, cellular: false)),
                       "Silent 30 s so far starting song 10 of 15: nothing loaded yet, on Wi-Fi")
        XCTAssertEqual(start.line(lasted: 4, ending: .sound, song: 1, of: 5, stream: Silence.Stream(kind: .onPhone, cellular: true)),
                       "Silent 4.0 s starting song 1 of 5: song saved on the phone")
    }

    func testTheLineEndsWithHowManyOfTheNextSongsAreOnThePhone() {
        var silence = Silence(moment: .midSong(at: 8))
        silence.did("moved to the lighter stream")
        XCTAssertEqual(silence.line(lasted: 11, ending: .sound, song: 1, of: 6, stream: cellular, savedAhead: 2, ofNext: 5),
                       "Silent 11 s mid-song (0:08 in, song 1 of 6): streaming the original on cellular; moved to the lighter stream; 2 of the next 5 saved")
    }

    func testNoSongNamesReachTheLog() {
        let line = Silence(moment: .midSong(at: 5)).line(lasted: 2, ending: .sound, song: 1, of: 1, stream: cellular)
        XCTAssertFalse(line.contains("\""), "counts and states only")
    }
}
