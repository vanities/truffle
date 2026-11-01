import XCTest
@testable import Truffle

/// The car log keeps the most recent lines across launches, and says how long a start took.
@MainActor
final class CarLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "carlog-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testKeepsOnlyTheMostRecentLines() {
        var entries: [CarLog.Entry] = []
        for index in 0..<(CarLog.limit + 5) {
            entries = CarLog.appending(CarLog.Entry(date: Date(timeIntervalSince1970: TimeInterval(index)), text: "\(index)"), to: entries)
        }
        XCTAssertEqual(entries.count, CarLog.limit)
        XCTAssertEqual(entries.first?.text, "5")
        XCTAssertEqual(entries.last?.text, "\(CarLog.limit + 4)")
    }

    func testSurvivesARelaunch() {
        let store = LibraryStore(directory: directory)
        CarLog(store: store).note("Car screen opened Truffle (app in the background)")
        XCTAssertEqual(CarLog(store: store).entries.map(\.text), ["Car screen opened Truffle (app in the background)"])
    }

    func testWritesHowLongTheSoundTook() throws {
        let log = CarLog(store: LibraryStore(directory: directory))
        log.expectSound(after: "Play command") { "stopped" }
        log.soundStarted(fromPhone: true)
        let line = try XCTUnwrap(log.entries.last?.text)
        XCTAssertTrue(line.hasPrefix("Sound "), line)
        XCTAssertTrue(line.hasSuffix("after Play command, from the phone"), line)
        log.soundStarted(fromPhone: false)
        XCTAssertEqual(log.entries.count, 1, "only a start someone was waiting on")
    }
}
