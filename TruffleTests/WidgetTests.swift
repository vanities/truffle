import SwiftUI
import WidgetKit
import XCTest
@testable import Truffle

@MainActor
final class WidgetTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func entry(_ date: Date) -> MixesEntry {
        MixesEntry(date: date, southern: false, calendar: calendar, region: Locale.Region("US"))
    }

    func testTheMediumWidgetOffersLikedAndTheSeasonsMixes() {
        let halloween = entry(date(2026, 10, 31))
        XCTAssertEqual(halloween.theme.moment, .halloween)
        XCTAssertEqual(halloween.tiles.map(\.mix.title), ["Liked", "Halloween Mix", "Fall Mix", "This Time Last Year"])
        let spring = entry(date(2027, 4, 20, hour: 22))
        XCTAssertEqual(spring.tiles.map(\.mix.title), ["Liked", "Spring Mix", "This Time Last Year", "Your Spring Favorites"])
        XCTAssertEqual(entry(date(2027, 7, 3)).tiles.map(\.mix.shortTitle), ["Liked", "Fourth of July", "Summer Mix", "Last Year"],
                       "short enough for a tile")
        XCTAssertTrue(spring.tiles.allSatisfy { $0.mix.kind == .liked || UIImage(named: "Mix-\($0.mix.art ?? "")") != nil },
                      "every mix tile has its cover")
    }

    func testTheWidgetRedrawsAtMidnightAndWhenNightDriveComesAndGoes() {
        XCTAssertEqual(MixesEntry.changes(after: date(2026, 10, 31), calendar: calendar),
                       [date(2026, 10, 31, hour: 20), date(2026, 11, 1, hour: 0), date(2026, 11, 1, hour: 5)])
    }

    /// Draws both sizes for a few seasons, and the control's face. With TEST_RUNNER_TRUFFLE_RENDER_DIR set
    /// on the `xcodebuild test` command line, the PNGs land there.
    func testTheWidgetDraws() throws {
        let folder = ProcessInfo.processInfo.environment["TRUFFLE_RENDER_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let days: [(String, Date)] = [("halloween", date(2026, 10, 31)), ("holidays", date(2026, 12, 15)),
                                      ("spring", date(2027, 4, 20)), ("fourth", date(2027, 7, 3))]
        for (name, day) in days {
            for (family, size) in [(WidgetFamily.systemSmall, CGSize(width: 170, height: 170)), (.systemMedium, CGSize(width: 364, height: 170))] {
                let item = entry(day)
                let renderer = ImageRenderer(content: Self.widget(MixesWidgetView(entry: item, family: family), theme: item.theme, size: size))
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage, "\(name) \(family)")
                XCTAssertEqual(image.size, size)
                if let folder {
                    try XCTUnwrap(image.pngData()).write(to: folder.appending(path: "widget-\(name)-\(family == .systemSmall ? "small" : "medium").png"))
                }
            }
        }
        let control = ImageRenderer(content: Self.controlFace)
        control.scale = 3
        if let folder, let png = control.uiImage?.pngData() {
            try png.write(to: folder.appending(path: "control-shuffle-all-standin.png"))
        }
    }

    /// The widget as the Home Screen frames it: its container background, content margins and corners.
    private static func widget(_ view: MixesWidgetView, theme: SeasonTheme, size: CGSize) -> some View {
        view
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(theme.gradient)
            .clipShape(.rect(cornerRadius: 22))
            .environment(\.colorScheme, .dark)
    }

    /// A stand-in for Control Center's round button and label, which only the system draws.
    private static var controlFace: some View {
        VStack(spacing: 8) {
            Image(systemName: "shuffle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(.white.opacity(0.18)))
            Text("Shuffle All")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(18)
        .background(Color(white: 0.1))
    }
}
