import SwiftUI
import UIKit
import os

/// The record, every day; for each holiday the record dresses up (a witch hat, a turkey tail…).
enum AppIconChoice: Equatable, Sendable {
    case record
    case dressed(Moment)

    /// The alternate icon set, or nil for the primary. project.yml lists every one of these.
    var assetName: String? {
        switch self {
        case .record: nil
        case .dressed(let moment): "AppIcon-" + moment.rawValue.prefix(1).uppercased() + moment.rawValue.dropFirst()
        }
    }

    var name: String {
        switch self {
        case .record: "record"
        case .dressed(let moment): moment.rawValue
        }
    }

    static func choice(holidays: Bool, theme: SeasonTheme) -> AppIconChoice {
        guard holidays, let moment = theme.moment else { return .record }
        return .dressed(moment)
    }
}

@MainActor
enum AppIconSwitcher {
    /// iOS shows its own "icon changed" note each time, so only switch when the answer changed.
    static func apply(settings: AppSettings, theme: SeasonTheme) {
        let wanted = AppIconChoice.choice(holidays: settings.holidayIcons, theme: theme)
        guard UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != wanted.assetName else { return }
        Logger.ui.info("[icon] → \(wanted.name, privacy: .public)")
        UIApplication.shared.setAlternateIconName(wanted.assetName) { error in
            if let error { Logger.ui.error("[icon] switch failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
