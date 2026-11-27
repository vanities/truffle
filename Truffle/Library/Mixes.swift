import Foundation

/// Date windows to read play history in.
enum HistoryWindows {
    /// Two weeks either side of today's date, in each earlier year back to the first play.
    static func aroundThisDate(_ date: Date, days: Int = 14, earliest: Date, calendar: Calendar = .current) -> [DateInterval] {
        var windows: [DateInterval] = []
        var yearsBack = 1
        while let then = calendar.date(byAdding: .year, value: -yearsBack, to: date),
              let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: then)),
              let end = calendar.date(byAdding: .day, value: days + 1, to: calendar.startOfDay(for: then)),
              end > earliest {
            windows.append(DateInterval(start: start, end: end))
            yearsBack += 1
            if yearsBack > 30 { break }
        }
        return windows
    }

    /// Each finished occurrence of `season` (its three whole months) before the one `date` is in.
    static func seasonWindows(_ season: Season, southern: Bool, before date: Date, earliest: Date,
                              calendar: Calendar = .current) -> [DateInterval] {
        let startMonth = season.startMonth(southern: southern)
        let currentYear = calendar.component(.year, from: date)
        var windows: [DateInterval] = []
        for year in stride(from: currentYear, through: currentYear - 30, by: -1) {
            guard let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 3, to: start) else { continue }
            if end > date { continue }
            if end <= earliest { break }
            windows.append(DateInterval(start: start, end: end))
        }
        return windows
    }
}

/// A mix Truffle made, as it was drawn. It plays the same songs in the same order until Regenerate draws it
/// again: tapped twice, a mix used to be two different hundred songs, and neither could be looked at.
struct SavedMix: Codable, Equatable, Sendable {
    var tracks: [Track]
    var madeAt: Date
}

/// The pure parts of building mixes, so they can be tested without a server.
enum MixBuilder {
    /// How long a made mix is kept on the phone once its season has passed.
    static let keptFor: TimeInterval = 120 * 86_400

    /// What a made mix is saved under, or nil for the ones that aren't kept: Shuffle All and Album Roulette are
    /// new every time on purpose, and Liked is the list itself. A season's mix is made once a year, and
    /// This Time Last Year once a week, since its two weeks either side of today move with the date.
    static func saveKey(for mix: Mix, on date: Date, calendar: Calendar = .current) -> String? {
        let year = calendar.component(.year, from: date)
        switch mix.kind {
        case .shuffleAll, .randomAlbum, .liked: return nil
        case .moment, .season: return "\(mix.kind.rawValue)-\(mix.art ?? mix.title)-\(year)"
        case .seasonFavorites: return "favorites-\(mix.title)-\(year)"
        case .lastYear: return "lastYear-\(calendar.component(.yearForWeekOfYear, from: date))-w\(calendar.component(.weekOfYear, from: date))"
        case .nightDrive: return "nightDrive"
        }
    }

    /// The primary-mood songs carry the mix and the secondary ones fill it out to `limit`, without
    /// repeats, in random order.
    static func moodMix<G: RandomNumberGenerator>(primary: [Track], secondary: [Track], limit: Int,
                                                  using generator: inout G) -> [Track] {
        var seen = Set<String>()
        let primary = primary.filter { seen.insert($0.id).inserted }.shuffled(using: &generator)
        let secondary = secondary.filter { seen.insert($0.id).inserted }.shuffled(using: &generator)
        let picked = Array(primary.prefix(limit)) + Array(secondary.prefix(max(0, limit - primary.count)))
        return picked.shuffled(using: &generator)
    }

    static func moodMix(primary: [Track], secondary: [Track], limit: Int) -> [Track] {
        var generator = SystemRandomNumberGenerator()
        return moodMix(primary: primary, secondary: secondary, limit: limit, using: &generator)
    }

    /// Song ids by how often they were played, most first; ties keep the order they came in.
    static func favorites(plays: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for id in plays {
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted { (counts[$0]!, -rank[$0]!) > (counts[$1]!, -rank[$1]!) }.prefix(limit).map { $0 }
    }

    /// The year a theme's hand-picked mix is filed under on `date`. New Year's shows from December 27, and its
    /// mix is named for the year it rings in ("New Year 2027"), so those last days of December look ahead.
    static func mixYear(theme: String, on date: Date, calendar: Calendar = .current) -> Int {
        let year = calendar.component(.year, from: date)
        return theme == "newyear" && calendar.component(.month, from: date) == 12 ? year + 1 : year
    }

    static func distinct(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
