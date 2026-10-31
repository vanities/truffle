import SwiftUI
import XCTest
@testable import Truffle

final class WindTests: XCTestCase {
    private let start: TimeInterval = 800_000_000
    private let scene = SeasonScene(theme: SeasonCalendar.theme(season: .fall), density: 1, skyTop: 64,
                                    size: CGSize(width: 402, height: 640), time: 0, still: false)

    func testGustsCarryLeavesSmoothly() {
        for index in 0..<6 {
            var previous = Gust(at: start, still: false).blow(index, carry: 1.4)
            for step in 1...(120 * 30) {
                let now = Gust(at: start + Double(step) / 30, still: false).blow(index, carry: 1.4)
                XCTAssertLessThan(hypot(now.dx - previous.dx, now.dy - previous.dy), 8, "leaf \(index) jumps at frame \(step)")
                previous = now
            }
        }
    }

    func testABlownLeafOnlyWrapsWhileOutOfSight() {
        let side: CGFloat = 26
        func x(_ step: Int) -> CGFloat {
            scene.wrap(200 + Gust(at: start + Double(step) / 30, still: false).blow(1, carry: 1.4).dx, margin: side)
        }
        var previous = x(0)
        var wraps = 0
        for step in 1...(300 * 30) {
            let now = x(step)
            if abs(now - previous) > 100 {
                wraps += 1
                for x in [previous, now] {
                    XCTAssert(x + side / 2 <= 0 || x - side / 2 >= scene.size.width, "wrapped at \(x), on screen")
                }
            }
            previous = now
        }
        XCTAssertGreaterThan(wraps, 5, "five minutes of gusts carry it round more than once")
    }

    func testStillIsCalm() {
        let calm = Gust(at: start + 3, still: true)
        XCTAssertEqual(calm.pushed, 0)
        XCTAssertEqual(calm.blow(3, carry: 1).dx, 0)
    }
}
