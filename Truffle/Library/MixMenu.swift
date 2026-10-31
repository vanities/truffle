import Foundation

enum MixKind: String, Codable, CaseIterable, Sendable {
    case shuffleAll, randomAlbum, liked, season, moment, lastYear, seasonFavorites, nightDrive
}

/// Something to play with one tap, on the home screen and in the car.
struct Mix: Identifiable, Hashable, Sendable {
    let kind: MixKind
    let title: String
    let subtitle: String
    let symbol: String
    /// The `Mix-<key>` cover in the asset catalog (scripts/generate-art.py).
    var art: String?

    var id: String { kind.rawValue }

    /// For tight spots: the car's grid and the widget's tiles.
    var shortTitle: String {
        switch kind {
        case .lastYear: "Last Year"
        case .seasonFavorites: "Favorites"
        case .randomAlbum: "Roulette"
        // "Fourth of July Mix" → "Fourth of July"; "Fall Mix" stays.
        default: title.count > 12 && title.hasSuffix(" Mix") ? String(title.dropLast(4)) : title
        }
    }

    static let shuffleAll = Mix(kind: .shuffleAll, title: "Shuffle All", subtitle: "No favorites", symbol: "shuffle")
    static let randomAlbum = Mix(kind: .randomAlbum, title: "Album Roulette", subtitle: "Spin to win", symbol: "square.stack.fill")
    static let liked = Mix(kind: .liked, title: "Liked", subtitle: "The good stuff", symbol: "heart.fill")
}

enum MixPlanner {
    /// The seasonal mixes on offer right now, most timely first.
    static func seasonal(theme: SeasonTheme, date: Date, calendar: Calendar = .current) -> [Mix] {
        var mixes: [Mix] = []
        let recipe = theme.recipe
        mixes.append(Mix(kind: theme.moment == nil ? .season : .moment, title: recipe.title, subtitle: recipe.subtitle,
                         symbol: recipe.symbol, art: theme.moment?.rawValue ?? theme.season.rawValue))
        if theme.moment != nil {
            let season = SeasonCalendar.theme(season: theme.season).recipe
            mixes.append(Mix(kind: .season, title: season.title, subtitle: season.subtitle, symbol: season.symbol,
                             art: theme.season.rawValue))
        }
        mixes.append(Mix(kind: .lastYear, title: "This Time Last Year", subtitle: "Remember these?",
                         symbol: "clock.arrow.circlepath", art: "lastYear"))
        mixes.append(Mix(kind: .seasonFavorites, title: "Your \(theme.season.title) Favorites", subtitle: "Greatest hits",
                         symbol: "star.fill", art: "favorites"))
        if SeasonCalendar.isNight(date, calendar: calendar) { mixes.append(nightDrive) }
        return mixes
    }

    static let nightDrive: Mix = {
        let night = MoodRecipe.nightDrive
        return Mix(kind: .nightDrive, title: night.title, subtitle: night.subtitle, symbol: night.symbol, art: "nightDrive")
    }()
}
