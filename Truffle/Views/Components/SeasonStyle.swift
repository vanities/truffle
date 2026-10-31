import SwiftUI
import os

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
