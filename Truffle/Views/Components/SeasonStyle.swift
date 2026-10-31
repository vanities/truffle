import SwiftUI
import UIKit
import os

// The colors the widget shares are in SeasonColors.swift; these need UIKit and stay in the app.
extension RGB {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

extension EnvironmentValues {
    /// The label color for buttons filled with the tint; RootView sets it with the tint.
    @Entry var onTintColor: Color = .white
}

extension SeasonTheme {
    /// The accent as text, links and controls wear it: deepened on light pages and lifted on dark ones
    /// until it reads (4.5:1, or 7:1 with Increase Contrast). Gradients and art keep `accentColor`.
    var tintColor: Color {
        let accent = accent
        return Color(uiColor: UIColor { traits in
            accent.tint(dark: traits.userInterfaceStyle == .dark, increasedContrast: traits.accessibilityContrast == .high).uiColor
        })
    }
    /// Words and symbols on a button filled with the tint (Play): white on the deeper light-mode tint,
    /// black on the brighter dark-mode one.
    var onTintColor: Color {
        let accent = accent
        return Color(uiColor: UIColor { traits in
            accent.tint(dark: traits.userInterfaceStyle == .dark, increasedContrast: traits.accessibilityContrast == .high).onColor.uiColor
        })
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
