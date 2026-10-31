import Foundation

/// Every mix Siri, Shortcuts and the widget can start by name: today's, as Home and the car list them,
/// and each holiday's and season's own mix whenever someone asks for it.
///
/// An id names a mix by its place ("moment", "season"), not its title, so a widget button drawn in
/// October plays whatever the moment is when it's tapped. Holidays and seasons out of their time are
/// `theme.<key>` ("theme.christmas").
enum MixCatalog {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let mix: Mix
        /// What `PlayerEngine.play(_:theme:)` builds the mix from.
        let theme: SeasonTheme
    }

    /// What Home and the car offer right now: Shuffle All, Liked, the season's mixes, Album Roulette.
    static func today(at date: Date, southern: Bool, calendar: Calendar = .current,
                      region: Locale.Region? = Locale.current.region) -> [Entry] {
        let theme = SeasonCalendar.theme(for: date, southern: southern, calendar: calendar, region: region)
        let mixes = [Mix.shuffleAll, .liked] + MixPlanner.seasonal(theme: theme, date: date, calendar: calendar) + [.randomAlbum]
        return mixes.map { Entry(id: $0.id, mix: $0, theme: theme) }
    }

    /// Today's, then Night Drive at any hour, then every other holiday and season.
    static func all(at date: Date, southern: Bool, calendar: Calendar = .current,
                    region: Locale.Region? = Locale.current.region) -> [Entry] {
        var entries = today(at: date, southern: southern, calendar: calendar, region: region)
        guard let current = entries.first?.theme else { return entries }
        if !entries.contains(where: { $0.id == MixPlanner.nightDrive.id }) {
            entries.append(Entry(id: MixPlanner.nightDrive.id, mix: MixPlanner.nightDrive, theme: current))
        }
        let shown = Set(entries.compactMap(\.mix.art))
        for moment in Moment.allCases where !shown.contains(moment.rawValue) {
            if moment == .fourthOfJuly, !SeasonCalendar.celebratesTheFourth(region) { continue }
            let theme = SeasonCalendar.theme(moment: moment, season: current.season)
            entries.append(Entry(id: "theme.\(moment.rawValue)", mix: mix(.moment, theme.recipe, art: moment.rawValue), theme: theme))
        }
        for season in Season.allCases where !shown.contains(season.rawValue) {
            let theme = SeasonCalendar.theme(season: season)
            entries.append(Entry(id: "theme.\(season.rawValue)", mix: mix(.season, theme.recipe, art: season.rawValue), theme: theme))
        }
        return entries
    }

    /// A widget button can outlive its moment (Halloween's mix tapped on November 2nd); then it's the
    /// season's.
    static func entry(id: String, at date: Date, southern: Bool, calendar: Calendar = .current,
                      region: Locale.Region? = Locale.current.region) -> Entry? {
        let entries = all(at: date, southern: southern, calendar: calendar, region: region)
        if let found = entries.first(where: { $0.id == id }) { return found }
        return id == MixKind.moment.rawValue ? entries.first { $0.id == MixKind.season.rawValue } : nil
    }

    private static func mix(_ kind: MixKind, _ recipe: MoodRecipe, art: String) -> Mix {
        Mix(kind: kind, title: recipe.title, subtitle: recipe.subtitle, symbol: recipe.symbol, art: art)
    }
}
