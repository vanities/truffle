import SwiftUI
import UIKit
import os

/// The three icons. The record is the default (the one Adam and Angela liked); the note is the fall
/// one (Adam's); the headphones stay as an option.
enum AppIconChoice: String, CaseIterable, Codable, Sendable {
    case record, note, headphones

    /// The alternate icon set, or nil for the primary.
    var assetName: String? {
        switch self {
        case .record: nil
        case .note: "AppIcon-Note"
        case .headphones: "AppIcon-Headphones"
        }
    }

    var title: String {
        switch self {
        case .headphones: "Headphones"
        case .note: "Note"
        case .record: "Record"
        }
    }

    var preview: String { "IconPreview-\(rawValue)" }

    /// Matching the season puts the note on in the fall (Halloween and Thanksgiving included).
    static func choice(chosen: AppIconChoice, matchSeason: Bool, theme: SeasonTheme) -> AppIconChoice {
        matchSeason && theme.season == .fall ? .note : chosen
    }
}

@MainActor
enum AppIconSwitcher {
    /// iOS shows its own "icon changed" note each time, so only switch when the answer changed.
    static func apply(settings: AppSettings, theme: SeasonTheme) {
        let wanted = AppIconChoice.choice(chosen: settings.appIcon, matchSeason: settings.seasonalIcon, theme: theme)
        guard UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != wanted.assetName else { return }
        Logger.ui.info("[icon] → \(wanted.rawValue, privacy: .public)")
        UIApplication.shared.setAlternateIconName(wanted.assetName) { error in
            if let error { Logger.ui.error("[icon] switch failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
