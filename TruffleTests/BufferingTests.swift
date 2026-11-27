import XCTest
@testable import Truffle

final class BufferingTests: XCTestCase {
    private func sample(waited: TimeInterval = 6, ahead: TimeInterval = 0, fill: Double? = nil, idle: TimeInterval = 0,
                        complete: Bool = false) -> Buffering.Sample {
        Buffering.Sample(waited: waited, ahead: ahead, fill: fill, idle: idle, complete: complete)
    }

    func testASongWhoseConnectionJustCameBackIsNotCalledSlow() {
        // A minute of nothing, then its first half second: over the whole wait that's a crawl, but it has only
        // been arriving for a moment.
        var back = Buffering.Sample(waited: 51.5, ahead: 0.5, fill: 0.1, idle: 0, arriving: 0.5)
        XCTAssertEqual(verdict(back), .wait, "the rate isn't judged until it has been arriving a few seconds")
        back.arriving = 4.5
        XCTAssertEqual(verdict(back), .lighter, "still that slow after arriving steadily: the lighter stream")
    }

    private func verdict(_ sample: Buffering.Sample, earlyStarts: Int = 0, canLighten: Bool = true) -> Buffering.Verdict {
        Buffering.verdict(for: sample, earlyStarts: earlyStarts, canLighten: canLighten)
    }

    func testASongArrivingFasterThanItPlaysStartsOnAFewSeconds() {
        XCTAssertEqual(verdict(sample(ahead: 3, fill: 2.8)), .start)
        XCTAssertEqual(verdict(sample(ahead: 2.9, fill: 2.8)), .wait, "not on a sliver")
        XCTAssertEqual(verdict(sample(ahead: 10, fill: 1.1)), .wait, "barely ahead is AVPlayer's call")
        XCTAssertEqual(verdict(sample(ahead: 10, fill: nil)), .wait, "no rate measured yet")
    }

    func testEachEarlyStartAsksForMoreInHand() {
        XCTAssertEqual([0, 1, 2, 3, 9].map(Buffering.needed(earlyStarts:)), [3, 6, 12, 24, 24])
        XCTAssertEqual(verdict(sample(ahead: 5, fill: 2), earlyStarts: 1), .wait)
        XCTAssertEqual(verdict(sample(ahead: 6, fill: 2), earlyStarts: 1), .start)
    }

    func testPlentyInHandOrTheWholeSongStartsWhateverTheRate() {
        XCTAssertEqual(verdict(sample(ahead: 30, fill: 0.2), canLighten: false), .start)
        XCTAssertEqual(verdict(sample(ahead: 4, fill: 0, complete: true)), .start, "the rest of the song is in")
    }

    /// The truck on a weak signal: a FLAC arriving at 0.8 times its bitrate (measured: 0.7 to 0.9).
    func testAnOriginalThatFallsBehindGoesToTheLighterStream() {
        XCTAssertEqual(verdict(sample(waited: 4, ahead: 3, fill: 0.8)), .lighter)
        XCTAssertEqual(verdict(sample(waited: 3.5, ahead: 3, fill: 0.8)), .wait, "the rate needs a few seconds to mean anything")
        XCTAssertEqual(verdict(sample(waited: 8, ahead: 3, fill: 0.8), canLighten: false), .wait,
                       "already the lighter stream, or transcodes are resting")
        XCTAssertEqual(verdict(sample(waited: 8, ahead: 3, fill: 0.97)), .wait, "close enough that AVPlayer will get there")
        XCTAssertEqual(verdict(sample(waited: 8, ahead: 0, fill: 0.01, idle: 3)), .wait, "a trickle is a dying connection, not a slow one")
    }

    func testNothingArrivingForTenSecondsReconnects() {
        XCTAssertEqual(verdict(sample(waited: 10, ahead: 0, fill: 0, idle: 10)), .reconnect)
        XCTAssertEqual(verdict(sample(waited: 9, ahead: 0, fill: 0, idle: 9)), .wait)
        XCTAssertEqual(verdict(sample(waited: 40, ahead: 2, fill: 0.5, idle: 1)), .lighter, "slow isn't dead")
    }

    func testFillIsSongSecondsPerSecond() {
        XCTAssertNil(Buffering.fill([]))
        XCTAssertNil(Buffering.fill([(at: 0, end: 0), (at: 1.5, end: 3)]), "under two seconds says nothing")
        XCTAssertEqual(Buffering.fill([(at: 0, end: 10), (at: 2, end: 11), (at: 4, end: 13.2)]) ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(Buffering.fill([(at: 0, end: 50), (at: 4, end: 9)]), 0, "a seek back isn't negative progress")
    }

    func testAWeakSignalRestsOriginalsLongerEachTime() {
        var signal = WeakSignal()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(signal.isWeak(at: start))
        XCTAssertEqual(signal.fellBehind(at: start), 300)
        XCTAssertTrue(signal.isWeak(at: start.addingTimeInterval(299)))
        XCTAssertFalse(signal.isWeak(at: start.addingTimeInterval(300)), "originals get another try")
        XCTAssertEqual(signal.fellBehind(at: start.addingTimeInterval(400)), 600)
        XCTAssertEqual(signal.fellBehind(at: start.addingTimeInterval(2000)), 1200)
        XCTAssertEqual(signal.fellBehind(at: start.addingTimeInterval(4000)), 1200, "twenty minutes at most")
        signal.clear()
        XCTAssertFalse(signal.isWeak(at: start.addingTimeInterval(4001)), "a new network starts over")
        XCTAssertEqual(signal.fellBehind(at: start.addingTimeInterval(5000)), 300)
    }

    func testAWeakSignalStreamsTheLighterCopyEvenWithDataSaverOff() {
        XCTAssertEqual(DataSaver.mode(enabled: false, metered: false, weakSignal: true), .dataSaver)
        XCTAssertEqual(DataSaver.mode(enabled: false, metered: true, weakSignal: false), .original)
        var health = TranscodeHealth()
        health.failed("7", at: .now)
        XCTAssertEqual(DataSaver.mode(enabled: false, metered: false, weakSignal: true, song: "7", health: health, now: .now), .original,
                       "a song whose transcode failed keeps its original")
        XCTAssertEqual(DataSaver.mode(enabled: false, metered: false, weakSignal: true, song: "8", health: health, now: .now), .dataSaver)
    }
}
