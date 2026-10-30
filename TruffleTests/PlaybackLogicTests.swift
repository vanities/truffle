import XCTest
@testable import Truffle

final class PlaybackLogicTests: XCTestCase {
    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { Track(id: "\($0)", title: "Song \($0)", artist: "A", album: "B") }
    }

    func testNextAndPreviousRespectRepeat() {
        var queue = PlayQueue()
        queue.replace(with: tracks(3), startAt: 2)
        XCTAssertNil(queue.indexForNext(), "end of the queue")
        XCTAssertNil(queue.indexAfterEnd())
        queue.repeatMode = .all
        XCTAssertEqual(queue.indexForNext(), 0)
        queue.repeatMode = .one
        XCTAssertEqual(queue.indexAfterEnd(), 2, "repeat one replays the song when it ends")
        XCTAssertEqual(queue.indexForNext(), 0, "but Next still moves on")
        queue.replace(with: tracks(3), startAt: 0)
        queue.repeatMode = .off
        XCTAssertNil(queue.indexForPrevious())
        queue.repeatMode = .all
        XCTAssertEqual(queue.indexForPrevious(), 2)
    }

    func testPlayNextGoesRightAfterTheCurrentSong() {
        var queue = PlayQueue()
        queue.replace(with: tracks(3), startAt: 1)
        queue.insertNext([Track(id: "x", title: "X", artist: "A", album: "B")])
        XCTAssertEqual(queue.tracks.map(\.id), ["0", "1", "x", "2"])
        queue.append([Track(id: "y", title: "Y", artist: "A", album: "B")])
        XCTAssertEqual(queue.upcoming.map(\.id), ["x", "2", "y"])
    }

    func testEditingUpcomingNeverTouchesWhatsPlaying() {
        var queue = PlayQueue()
        queue.replace(with: tracks(5), startAt: 1)
        queue.removeUpcoming(at: IndexSet([0]))
        XCTAssertEqual(queue.tracks.map(\.id), ["0", "1", "3", "4"])
        XCTAssertEqual(queue.current?.id, "1")
        queue.moveUpcoming(from: IndexSet([1]), to: 0)
        XCTAssertEqual(queue.upcoming.map(\.id), ["4", "3"])
    }

    func testAnEndlessShuffleForgetsOldSongs() {
        var queue = PlayQueue()
        queue.replace(with: tracks(100), startAt: 80)
        queue.trimPlayed(keeping: 50)
        XCTAssertEqual(queue.index, 50)
        XCTAssertEqual(queue.current?.id, "80")
        XCTAssertEqual(queue.tracks.count, 70)
    }

    func testUpdatedDetailsReplaceEveryCopy() {
        var queue = PlayQueue()
        let song = Track(id: "s", title: "S", artist: "A", album: "B")
        queue.replace(with: [song, tracks(1)[0], song])
        var detailed = song
        detailed.loudness = -9
        queue.update(detailed)
        XCTAssertEqual(queue.tracks.filter { $0.id == "s" }.map(\.loudness), [-9, -9])
    }

    func testLoudSongsComeDownAndQuietOnesPlayFull() {
        var loud = Track(id: "1", title: "Loud", artist: "A", album: "B")
        loud.loudness = -12.74
        XCTAssertEqual(Loudness.volume(for: loud, albumMode: false), Float(pow(10, -3.26 / 20)), accuracy: 0.0001)
        var quiet = loud
        quiet.loudness = -22
        XCTAssertEqual(Loudness.volume(for: quiet, albumMode: false), 1)
        XCTAssertEqual(Loudness.volume(for: Track(id: "2", title: "?", artist: "A", album: "B"), albumMode: false), 1,
                       "no analysis yet: full volume")
    }

    func testAlbumsKeepTheirOwnDynamics() {
        // A quiet interlude on a loud album: in album order it gets the album's level, not its own.
        var interlude = Track(id: "1", title: "Interlude", artist: "A", album: "B")
        interlude.loudness = -20
        interlude.gain = -4
        interlude.albumGain = -12
        XCTAssertEqual(Loudness.level(of: interlude, albumMode: true), -12)
        XCTAssertEqual(Loudness.level(of: interlude, albumMode: false), -20)
        XCTAssertLessThan(Loudness.volume(for: interlude, albumMode: true), 1)
        XCTAssertEqual(Loudness.volume(for: interlude, albumMode: false), 1)
    }
}
