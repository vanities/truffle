import XCTest
@testable import Truffle

/// Which transitions crossfade, when the fade starts, and the curves. The playing itself is PlayerEngine's.
final class CrossfadeTests: XCTestCase {
    private let shuffled = PlaySource(kind: .playlist, title: "Road Trip", id: "901", shuffled: true)

    private func song(_ id: String, album: String = "a", track: Int? = nil, disc: Int? = 1) -> Track {
        Track(id: id, title: "Song \(id)", artist: "A", album: "Album \(album)", albumID: album, trackNumber: track,
              discNumber: disc, duration: 200)
    }

    private func decide(_ seconds: Int = 6, source: PlaySource? = .shuffleAll, repeatMode: RepeatMode = .off,
                        from current: Track, length: TimeInterval = 200, to next: Track,
                        nextLength: TimeInterval = 180) -> Crossfade.Decision {
        Crossfade.decide(seconds: seconds, source: source, repeatMode: repeatMode, from: current, length: length,
                         to: next, length: nextLength)
    }

    func testShuffleAllFadesForTheChosenLengthAtTheEnd() {
        XCTAssertEqual(decide(from: song("1", album: "a", track: 3), to: song("2", album: "b", track: 7)),
                       .fade(.init(start: 194, length: 6)))
        XCTAssertEqual(decide(10, from: song("1"), length: 240.5, to: song("2", album: "b")),
                       .fade(.init(start: 230.5, length: 10)))
    }

    func testOffMeansGapless() {
        XCTAssertEqual(decide(0, from: song("1"), to: song("2", album: "b")), .gapless(.off))
    }

    func testOnlyShuffleAllAndShuffledPlaylistsFade() {
        let next = song("2", album: "b")
        XCTAssertEqual(decide(source: shuffled, from: song("1"), to: next), .fade(.init(start: 194, length: 6)))
        let inOrder = PlaySource(kind: .playlist, title: "Halloween 2026", id: "903")
        XCTAssertEqual(decide(source: inOrder, from: song("1"), to: next), .gapless(.notShuffle), "a sequenced mix")
        for kind in [PlaySource.Kind.album, .artist, .mix, .liked, .search, .songs] {
            let source = PlaySource(kind: kind, title: "x", shuffled: true)
            XCTAssertEqual(decide(source: source, from: song("1"), to: next), .gapless(.notShuffle), kind.rawValue)
        }
        XCTAssertEqual(decide(source: nil, from: song("1"), to: next), .gapless(.notShuffle))
    }

    func testAlbumNeighborsStayGaplessEvenInAShuffle() {
        XCTAssertEqual(decide(from: song("1", track: 4), to: song("2", track: 5)), .gapless(.albumOrder))
        XCTAssertEqual(decide(from: song("1", track: 12, disc: 1), to: song("2", track: 1, disc: 2)), .gapless(.albumOrder),
                       "the next disc's first song")
        XCTAssertEqual(decide(from: song("1", track: 4, disc: nil), to: song("2", track: 5, disc: nil)), .gapless(.albumOrder),
                       "no disc numbers means one disc")
        XCTAssertEqual(decide(from: song("1", track: 4), to: song("2", track: 9)), .fade(.init(start: 194, length: 6)),
                       "same album, not next to each other")
        XCTAssertEqual(decide(from: song("1", track: 5), to: song("2", track: 4)), .fade(.init(start: 194, length: 6)),
                       "backwards isn't album order")
        XCTAssertEqual(decide(from: song("1", album: "a", track: 4), to: song("2", album: "b", track: 5)),
                       .fade(.init(start: 194, length: 6)), "a different album")
        XCTAssertEqual(decide(from: song("1"), to: song("2")), .fade(.init(start: 194, length: 6)), "no track numbers")
    }

    func testRepeatOneAndTheSameSongNeverFade() {
        XCTAssertEqual(decide(repeatMode: .one, from: song("1"), to: song("2", album: "b")), .gapless(.repeatOne))
        XCTAssertEqual(decide(repeatMode: .all, from: song("1"), to: song("1")), .gapless(.sameSong))
    }

    func testShortSongsGetShorterFadesAndTinyOnesNone() {
        XCTAssertEqual(decide(10, from: song("1"), length: 20, to: song("2", album: "b")), .fade(.init(start: 15, length: 5)),
                       "a quarter of the shorter song at most")
        XCTAssertEqual(decide(10, from: song("1"), length: 200, to: song("2", album: "b"), nextLength: 12),
                       .fade(.init(start: 197, length: 3)), "the incoming song counts too")
        XCTAssertEqual(decide(from: song("1"), length: 3, to: song("2", album: "b")), .gapless(.tooShort))
        XCTAssertEqual(decide(from: song("1"), length: 0, to: song("2", album: "b")), .gapless(.tooShort), "length unknown")
    }

    func testCurvesKeepTheBlendAtFullPower() {
        XCTAssertEqual(Crossfade.gains(at: 0).outgoing, 1)
        XCTAssertEqual(Crossfade.gains(at: 0).incoming, 0)
        XCTAssertEqual(Crossfade.gains(at: 1).outgoing, 0, accuracy: 0.0001)
        XCTAssertEqual(Crossfade.gains(at: 1).incoming, 1)
        XCTAssertEqual(Crossfade.gains(at: 0.5).outgoing, Crossfade.gains(at: 0.5).incoming, accuracy: 0.0001, "they cross halfway")
        var last = Crossfade.gains(at: 0)
        for step in 1...100 {
            let gains = Crossfade.gains(at: Double(step) / 100)
            XCTAssertEqual(gains.outgoing * gains.outgoing + gains.incoming * gains.incoming, 1, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(gains.outgoing, last.outgoing)
            XCTAssertGreaterThanOrEqual(gains.incoming, last.incoming)
            last = gains
        }
        XCTAssertEqual(Crossfade.gains(at: -1).outgoing, 1, "clamped")
        XCTAssertEqual(Crossfade.gains(at: 2).incoming, 1, "clamped")
    }

    func testProgressFollowsTheOutgoingSongsClock() {
        XCTAssertEqual(Crossfade.progress(at: 194, start: 194, length: 6), 0)
        XCTAssertEqual(Crossfade.progress(at: 197, start: 194, length: 6), 0.5)
        XCTAssertEqual(Crossfade.progress(at: 201, start: 194, length: 6), 1)
        XCTAssertEqual(Crossfade.progress(at: 100, start: 194, length: 6), 0)
        XCTAssertEqual(Crossfade.progress(at: .nan, start: 194, length: 6), 0)
    }

    func testEveryChoiceIsOffOrAFewSeconds() {
        XCTAssertEqual(Crossfade.choices, [0, 3, 6, 10])
    }
}
