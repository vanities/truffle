import XCTest
@testable import Truffle

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testBothSettingsStartOnAndALaunchArgumentTurnsThemOff() throws {
        let suite = "AppSettingsTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = AppSettings(defaults: defaults)
        XCTAssertTrue(fresh.playInTheCar)
        XCTAssertTrue(fresh.holidaysInSeason)
        // `-settings.playInTheCar NO` arrives as the string "NO".
        defaults.set("NO", forKey: "settings.playInTheCar")
        defaults.set("NO", forKey: "settings.holidaysInSeason")
        let argued = AppSettings(defaults: defaults)
        XCTAssertFalse(argued.playInTheCar)
        XCTAssertFalse(argued.holidaysInSeason)
        argued.playInTheCar = true
        XCTAssertTrue(AppSettings(defaults: defaults).playInTheCar, "a toggle in Settings sticks")
    }
}
