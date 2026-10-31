import XCTest
@testable import Truffle

final class EventScheduleTests: XCTestCase {
    /// Every start in `hours` hours, found by stepping through time.
    private func starts(_ schedule: EventSchedule, hours: Double = 1, from: TimeInterval = 800_000_000) -> [TimeInterval] {
        var found: [TimeInterval] = []
        var lastIndex: Int?
        var time = from
        while time < from + hours * 3600 {
            if let event = schedule.occurrence(at: time), event.index != lastIndex {
                found.append(time - event.elapsed)
                lastIndex = event.index
            }
            time += 0.25
        }
        return found
    }

    func testSantaFliesByAboutOnceAMinute() {
        let schedule = EventSchedule.flyby
        let found = starts(schedule)
        XCTAssertEqual(Double(found.count), 3600 / schedule.period, accuracy: 2)
        let gaps = zip(found.dropFirst(), found).map { $0 - $1 }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, schedule.period - schedule.wander - 0.3, "never two in a row")
        XCTAssertLessThanOrEqual(gaps.max() ?? .infinity, schedule.period + schedule.wander + 0.3)
        XCTAssertGreaterThan(Set(gaps.map { Int($0) }).count, 5, "not a metronome")
    }

    func testAnEventRunsItsWholeLengthOnce() {
        let schedule = EventSchedule(period: 30, duration: 6, wander: 10)
        for index in 0..<50 {
            let start = schedule.start(of: index)
            XCTAssertGreaterThanOrEqual(start, Double(index) * 30)
            XCTAssertLessThanOrEqual(start + 6, Double(index + 1) * 30, "an event ends inside its own window")
            XCTAssertEqual(schedule.occurrence(at: start + 0.01)?.index, index)
            XCTAssertEqual(schedule.occurrence(at: start + 3)?.progress ?? 0, 0.5, accuracy: 0.001)
            XCTAssertNil(schedule.occurrence(at: start + 6.01))
            XCTAssertNil(schedule.occurrence(at: start - 0.01))
        }
    }

    func testRightAwayStartsTwoSecondsInForCaptures() {
        let now: TimeInterval = 812_345_678.5
        let schedule = EventSchedule.rightAway(.flyby, now: now)
        XCTAssertNil(schedule.occurrence(at: now + 1.9))
        XCTAssertEqual(schedule.occurrence(at: now + 2.1)?.elapsed ?? -1, 0.1, accuracy: 0.001)
        XCTAssertNotNil(schedule.occurrence(at: now + 2 + 14 + 1), "and again 14 seconds later")
        XCTAssertEqual(schedule.duration, EventSchedule.flyby.duration)
    }

    func testFireworksComeMoreOftenOnTheFourthThanAtNewYear() {
        XCTAssertLessThan(EventSchedule.fourthFireworks.period, EventSchedule.newYearFireworks.period)
        XCTAssertEqual(Double(starts(.fourthFireworks).count), 3600 / EventSchedule.fourthFireworks.period, accuracy: 2)
    }
}
