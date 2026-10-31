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

/// The pure parts of building mixes, so they can be tested without a server.
enum MixBuilder {
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

    static func distinct(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
