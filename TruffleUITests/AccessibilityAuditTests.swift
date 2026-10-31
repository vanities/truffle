import UIKit
import XCTest

/// Xcode's accessibility audit (contrast, descriptions, hit regions, Dynamic Type, clipped text, traits)
/// on every screen of the built-in demo library, at the default text size and the largest accessibility
/// size. `make a11y` runs it in light and dark on its own simulator. `TRUFFLE_DATE=2027-04-12T09:00` (set
/// as `TEST_RUNNER_TRUFFLE_DATE`) audits another season; `TRUFFLE_DUMP=1` prints each screen's
/// accessibility tree.
final class AccessibilityAuditTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor func testSignIn() throws {
        try audit("sign in", signedIn: false) { $0.buttons["Take it for a spin"] }
    }

    @MainActor func testHome() throws {
        try audit("home") { $0.buttons["Shuffle All"] }
    }

    @MainActor func testHomeShelves() throws {
        try audit("home shelves", scene: "mixes") { $0.staticTexts["Recently Added"] }
    }

    @MainActor func testPlayer() throws {
        try audit("player", scene: "player") { $0.buttons["Close"] }
    }

    @MainActor func testLibrary() throws {
        try audit("library", scene: "library") { $0.navigationBars["Library"] }
    }

    @MainActor func testAlbums() throws {
        try audit("albums", scene: "albums") { $0.navigationBars["Albums"] }
    }

    @MainActor func testAlbum() throws {
        try audit("album", scene: "album", extra: ["-TruffleAlbum", "Harvest Moon Parade"]) { $0.buttons["Shuffle"] }
    }

    @MainActor func testArtists() throws {
        try audit("artists", scene: "artists") { $0.navigationBars["Artists"] }
    }

    @MainActor func testLiked() throws {
        try audit("liked", scene: "liked") { $0.navigationBars["Liked Songs"] }
    }

    @MainActor func testPlaylist() throws {
        try audit("playlist", scene: "playlist") { $0.buttons["Edit"] }
    }

    @MainActor func testPlaylistEditor() throws {
        try audit("playlist editor", scene: "playlistFilled") { $0.navigationBars["New Playlist"] }
    }

    @MainActor func testStats() throws {
        try audit("stats", scene: "stats") { $0.staticTexts["Lately"] }
    }

    @MainActor func testSettings() throws {
        try audit("settings", scene: "settings") { $0.navigationBars["Settings"] }
    }

    @MainActor func testAppIcons() throws {
        try audit("app icons", scene: "icons") { $0.buttons["Record"] }
    }

    @MainActor func testSearch() throws {
        try audit("search", scene: "search") { $0.searchFields.firstMatch }
    }

    // MARK: -

    private static let largest = "UICTContentSizeCategoryAccessibilityXXXL"

    /// Launches the screen at the default text size and again at the largest (`TRUFFLE_SIZES=default` or
    /// `largest` for just one), and audits each.
    @MainActor private func audit(_ screen: String, scene: String? = nil, signedIn: Bool = true, extra: [String] = [],
                                  readyWhen ready: (XCUIApplication) -> XCUIElement) throws {
        let sizes: [String?] = switch ProcessInfo.processInfo.environment["TRUFFLE_SIZES"] {
        case "default": [nil]
        case "largest": [Self.largest]
        default: [nil, Self.largest]
        }
        // Apple-framework apps can meet contrast through Increase Contrast; without it, the system's own
        // secondary text only nearly passes, so that much is reported but doesn't fail.
        let increasedContrast = UIAccessibility.isDarkerSystemColorsEnabled
        for size in sizes {
            let name = size == nil ? screen : "\(screen) (largest text)"
            let app = XCUIApplication()
            app.launchArguments = ["-demo.active", signedIn ? "YES" : "NO", "-TruffleMute", "YES"] + extra
            if let scene { app.launchArguments += ["-TruffleScene", scene] }
            if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            if let date = ProcessInfo.processInfo.environment["TRUFFLE_DATE"] { app.launchArguments += ["-TruffleDate", date] }
            app.launch()
            dismissIconAlert(app)
            guard ready(app).waitForExistence(timeout: 20) else {
                XCTFail("\(name): never got ready")
                print("[a11y] \(name) never got ready:\n\(app.debugDescription)")
                continue
            }
            // Debug scenes scroll and open sheets a beat after they're reachable.
            sleep(2)
            if ProcessInfo.processInfo.environment["TRUFFLE_DUMP"] != nil {
                print("[a11y] tree of \(name):\n\(app.debugDescription)")
            }
            // Measured once: every query of a live element costs a round trip, and a gone one retries.
            let bars = Bars(screen: app.windows.firstMatch.frame,
                            tabBar: app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : .null,
                            navigationBar: app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame : .null)
            var found = 0, failing = 0
            try app.performAccessibilityAudit { issue in
                found += 1
                let element = try? issue.element?.snapshot()
                let waiver = element.flatMap { element in
                    Self.waivers.first { issue.auditType.contains($0.type) && $0.applies(element, bars) }
                }
                let nearlyPassed = issue.auditType == .contrast && issue.compactDescription.contains("nearly")
                let passes = waiver != nil || (nearlyPassed && !increasedContrast)
                if !passes { failing += 1 }
                print("[a11y] \(name): \(Self.typeName(issue.auditType))\(waiver.map { " (waived: \($0.reason))" } ?? (passes ? " (info)" : "")) "
                      + "\"\(element?.label ?? "")\" \(element.map { "\($0.elementType.rawValue) \($0.frame.integral)" } ?? "?") "
                      + ": \(issue.compactDescription)")
                return passes
            }
            print("[a11y] \(name): \(found) finding(s), \(failing) failing\(increasedContrast ? " (Increase Contrast on)" : "")")
            app.terminate()
        }
    }

    /// iOS says "You have changed the icon" when the season switches the app icon. SpringBoard shows it,
    /// and while it's up the app can't be audited.
    @MainActor private func dismissIconAlert(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for alert in [springboard.alerts.firstMatch, app.alerts.firstMatch] where alert.waitForExistence(timeout: 2) {
            print("[a11y] dismissing \"\(alert.label)\"")
            alert.buttons.firstMatch.tap()
        }
    }

    private static func typeName(_ type: XCUIAccessibilityAuditType) -> String {
        let names: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "element detection"), (.hitRegion, "hit region"),
            (.sufficientElementDescription, "description"), (.dynamicType, "dynamic type"),
            (.textClipped, "text clipped"), (.trait, "trait"),
        ]
        return names.filter { type.contains($0.0) }.map(\.1).joined(separator: "+")
    }

    /// Where the screen and its bars are, for the waivers.
    private struct Bars {
        let screen: CGRect
        let tabBar: CGRect
        let navigationBar: CGRect
    }

    /// Findings that aren't Truffle's to fix, each with why.
    private struct Waiver {
        let type: XCUIAccessibilityAuditType
        let reason: String
        let applies: @MainActor (any XCUIElementSnapshot, Bars) -> Bool
    }

    @MainActor private static let waivers: [Waiver] = [
        Waiver(type: .contrast, reason: "only partly on screen, under the tab bar's glass or past an edge; scrolled into "
               + "view, the same text is audited on its own") { element, bars in
            !bars.screen.contains(element.frame) || element.frame.intersects(bars.tabBar)
        },
        Waiver(type: .textClipped, reason: "UIKit's search field lays out its own placeholder") { element, _ in
            element.elementType == .searchField
        },
        Waiver(type: .dynamicType, reason: "toolbar buttons are UIKit's: their text stops growing with the navigation bar's "
               + "and a long press shows the Large Content Viewer") { element, bars in
            element.elementType == .button && bars.navigationBar.contains(element.frame)
        },
        Waiver(type: [.dynamicType, .textClipped], reason: "the mini player is a bar with a fixed height, like the tab "
               + "bar: its text stops growing and a long press shows the Large Content Viewer") { element, _ in
            element.identifier.hasPrefix("miniPlayer")
        },
    ]
}
