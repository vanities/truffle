import SwiftUI
import os

extension RGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

extension SeasonTheme {
    var accentColor: Color { accent.color }
    var colors: [Color] { palette.map(\.color) }
    /// Deep to bright, for cards and the home header.
    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// The small caps line over the greeting: "HALLOWEEN · FALL".
    var label: String {
        moment == nil ? title.uppercased() : "\(title.uppercased()) · \(season.title.uppercased())"
    }
}

/// The season, the moment and the mixes for right now, kept current while the app runs (Night Drive
/// appears at 8 pm, Halloween ends at midnight).
@MainActor @Observable
final class SeasonClock {
    private(set) var now = Date()
    private(set) var theme: SeasonTheme
    private(set) var mixes: [Mix]
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var timer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        let now = SeasonCalendar.now
        let theme = SeasonCalendar.theme(for: now, southern: settings.isSouthern)
        self.theme = theme
        mixes = MixPlanner.seasonal(theme: theme, date: now)
        self.now = now
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let date = SeasonCalendar.now
        let newTheme = SeasonCalendar.theme(for: date, southern: settings.isSouthern)
        let newMixes = MixPlanner.seasonal(theme: newTheme, date: date)
        now = date
        if newTheme != theme {
            Logger.ui.info("[season] \(self.theme.id, privacy: .public) → \(newTheme.id, privacy: .public)")
            theme = newTheme
        }
        if newMixes != mixes { mixes = newMixes }
    }
}
