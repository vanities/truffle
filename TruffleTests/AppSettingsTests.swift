import XCTest
@testable import Truffle

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testKeepHolidaysInSeasonStartsOnAndALaunchArgumentTurnsItOff() throws {
        let suite = "AppSettingsTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AppSettings(defaults: defaults).holidaysInSeason)
        // `-settings.holidaysInSeason NO` arrives as the string "NO".
        defaults.set("NO", forKey: "settings.holidaysInSeason")
        let argued = AppSettings(defaults: defaults)
        XCTAssertFalse(argued.holidaysInSeason)
        argued.holidaysInSeason = true
        XCTAssertTrue(AppSettings(defaults: defaults).holidaysInSeason, "a toggle in Settings sticks")
    }
}
