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
        try audit("app icons", scene: "icons") { $0.switches["Holiday Icons"] }
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
            let layout = Layout(app)
            var found = 0, failing = 0
            try app.performAccessibilityAudit { issue in
                found += 1
                let element = try? issue.element?.snapshot()
                let waiver = element.flatMap { element in
                    Self.waivers.lazy.compactMap { waiver in
                        waiver.type.contains(issue.auditType) ? waiver.applies(element, layout).map { (waiver.reason, $0) } : nil
                    }.first
                }
                let nearlyPassed = issue.auditType == .contrast && issue.compactDescription.contains("nearly")
                let passes = waiver != nil || (nearlyPassed && !increasedContrast)
                if !passes { failing += 1 }
                let verdict = waiver.map { " (waived: \($0.0)\($0.1.isEmpty ? "" : "; \($0.1)"))" } ?? (passes ? " (info)" : "")
                print("[a11y] \(name): \(Self.typeName(issue.auditType))\(verdict) \"\(element?.label ?? "")\" "
                      + "\(element.map { "\($0.elementType.rawValue) \($0.frame.integral)" } ?? "?") : \(issue.compactDescription)")
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

    /// The screen as the audit starts: where the bars are, and what it looks like. Measured once, since
    /// every query of a live element is a round trip and a gone one retries for seconds.
    private struct Layout {
        let screen: CGRect
        let tabBar: CGRect
        let navigationBar: CGRect
        /// The mini player's band above the tab bar.
        let accessory: CGRect
        /// Every button's frame, from one snapshot of the tree.
        let buttons: [CGRect]
        let image: UIImage

        @MainActor init(_ app: XCUIApplication) {
            screen = app.windows.firstMatch.frame
            tabBar = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : .null
            navigationBar = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame : .null
            let miniPlayer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Now playing:'")).firstMatch
            accessory = miniPlayer.exists ? CGRect(x: screen.minX, y: miniPlayer.frame.minY, width: screen.width,
                                                   height: miniPlayer.frame.height) : .null
            var buttons: [CGRect] = []
            func collect(_ node: any XCUIElementSnapshot) {
                if node.elementType == .button { buttons.append(node.frame) }
                node.children.forEach(collect)
            }
            if let tree = try? app.snapshot() { collect(tree) }
            self.buttons = buttons
            image = app.screenshot().image
        }

        /// Words that fill a button, as a Liquid Glass button's label does (Play, Shuffle), or that sit in
        /// the mini player's glass.
        func isOnGlass(_ frame: CGRect) -> Bool {
            accessory.contains(frame)
                || buttons.contains { $0.insetBy(dx: -1, dy: -1).contains(frame) && frame.height >= $0.height - 2 }
        }

        /// The contrast of what's drawn in `frame`, as WCAG computes it: the middle luminance (the
        /// background) against the extreme on the side farther from it (the words).
        func contrast(in frame: CGRect) -> Double? {
            guard let cgImage = image.cgImage else { return nil }
            let scale = image.scale
            let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            guard rect.width >= 4, rect.height >= 4, let crop = cgImage.cropping(to: rect) else { return nil }
            let width = crop.width, height = crop.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            func linear(_ value: UInt8) -> Double {
                let channel = Double(value) / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            let luminances = stride(from: 0, to: pixels.count, by: 4).map {
                0.2126 * linear(pixels[$0]) + 0.7152 * linear(pixels[$0 + 1]) + 0.0722 * linear(pixels[$0 + 2])
            }.sorted()
            let background = luminances[luminances.count / 2]
            let darkest = luminances[luminances.count / 100], lightest = luminances[luminances.count - 1 - luminances.count / 100]
            let words = lightest - background > background - darkest ? lightest : darkest
            return (max(words, background) + 0.05) / (min(words, background) + 0.05)
        }
    }

    /// Findings that aren't Truffle's to fix, each with why. `applies` answers nil when it doesn't, or the
    /// evidence (empty when the reason says it all).
    private struct Waiver {
        let type: XCUIAccessibilityAuditType
        let reason: String
        let applies: @MainActor (any XCUIElementSnapshot, Layout) -> String?
    }

    @MainActor private static let waivers: [Waiver] = [
        Waiver(type: .contrast, reason: "only partly on screen, under the tab bar's glass or past an edge; scrolled into "
               + "view, the same text is audited on its own") { element, layout in
            !layout.screen.contains(element.frame) || element.frame.intersects(layout.tabBar) ? "" : nil
        },
        // The audit misreads text on Liquid Glass (Play, Shuffle, the mini player); the screenshot settles it.
        Waiver(type: .contrast, reason: "on Liquid Glass, measured from the screenshot instead") { element, layout in
            guard layout.isOnGlass(element.frame), let measured = layout.contrast(in: element.frame), measured >= 4.5 else { return nil }
            return String(format: "%.1f:1", measured)
        },
        Waiver(type: .textClipped, reason: "UIKit's search field lays out its own placeholder") { element, _ in
            element.elementType == .searchField ? "" : nil
        },
        Waiver(type: .dynamicType, reason: "toolbar buttons are UIKit's: their text stops growing with the navigation bar's "
               + "and a long press shows the Large Content Viewer") { element, layout in
            element.elementType == .button && layout.navigationBar.contains(element.frame) ? "" : nil
        },
        Waiver(type: [.dynamicType, .textClipped], reason: "the mini player is a bar with a fixed height, like the tab "
               + "bar: its text stops growing and a long press shows the Large Content Viewer") { element, layout in
            layout.accessory.contains(element.frame) ? "" : nil
        },
    ]
}
