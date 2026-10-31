import Foundation

/// One play in the server's history: the song, and when Plex counted it (`viewedAt`, seconds since
/// 1970). Plex counts a song once it's 90% played.
struct PlayRecord: Codable, Hashable, Sendable {
    let trackID: String
    let viewedAt: Int

    var date: Date { Date(timeIntervalSince1970: TimeInterval(viewedAt)) }
}

/// What Stats knows about a played song: from `/library/metadata/{ids}` while it's in the library, or
/// from the history entry itself (names as they were) once it isn't.
struct SongFacts: Codable, Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    var albumID: String?
    var albumArtist: String?
    var albumArtistID: String?
    var thumb: String?
    var artistThumb: String?
    var duration: TimeInterval = 0
    var viewCount: Int?
    var lastViewedAt: Int?
    var inLibrary = true

    init(title: String, artist: String, album: String, albumID: String? = nil, albumArtist: String? = nil,
         albumArtistID: String? = nil, thumb: String? = nil, artistThumb: String? = nil, duration: TimeInterval = 0,
         viewCount: Int? = nil, lastViewedAt: Int? = nil, inLibrary: Bool = true) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumID = albumID
        self.albumArtist = albumArtist
        self.albumArtistID = albumArtistID
        self.thumb = thumb
        self.artistThumb = artistThumb
        self.duration = duration
        self.viewCount = viewCount
        self.lastViewedAt = lastViewedAt
        self.inLibrary = inLibrary
    }

    /// `inLibrary: false` is a history entry standing in for a song that's gone: its ids lead nowhere.
    init?(_ metadata: PlexMetadata, inLibrary: Bool = true) {
        guard !metadata.ratingKey.isEmpty, metadata.type == nil || metadata.type == "track" else { return nil }
        self.init(
            title: metadata.title ?? "Untitled",
            // A compilation's track carries its own artist in originalTitle, as in `Track`.
            artist: metadata.originalTitle ?? metadata.grandparentTitle ?? "Unknown Artist",
            album: metadata.parentTitle ?? "",
            albumID: inLibrary ? metadata.parentRatingKey : nil,
            albumArtist: metadata.grandparentTitle,
            albumArtistID: inLibrary ? metadata.grandparentRatingKey : nil,
            thumb: metadata.parentThumb ?? metadata.thumb ?? metadata.grandparentThumb,
            artistThumb: metadata.grandparentThumb,
            duration: TimeInterval(metadata.duration ?? 0) / 1000,
            viewCount: metadata.viewCount,
            lastViewedAt: metadata.lastViewedAt,
            inLibrary: inLibrary
        )
    }

    /// The artist's page, when the song's artist is the album's (a compilation's guest has none).
    var artistPageID: String? { artist == albumArtist ? albumArtistID : nil }
}

/// Everything the Stats tab shows, worked out from play history. Pure, so it's tested without a server.
struct ListeningStats: Equatable, Sendable {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case week, month, year, all

        var id: String { rawValue }

        /// Where the period starts; nil for all time.
        func start(now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start
            case .month: calendar.dateInterval(of: .month, for: now)?.start
            case .year: calendar.dateInterval(of: .year, for: now)?.start
            case .all: nil
            }
        }
    }

    struct Total: Equatable, Sendable {
        var plays = 0
        var seconds: TimeInterval = 0
        var songs = 0
        var artists = 0
    }

    struct Month: Equatable, Identifiable, Sendable {
        var start: Date
        var plays: Int
        var seconds: TimeInterval

        var id: Date { start }
    }

    /// A song, album or artist in a top list.
    struct Ranked: Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var subtitle: String?
        var thumb: String?
        var plays: Int
        var seconds: TimeInterval
        var lastPlayed: Date?
        /// Where a tap goes; nil when it's no longer in the library.
        var trackID: String?
        var albumID: String?
        var artistID: String?
    }

    struct Top: Equatable, Sendable {
        var artists: [Ranked] = []
        var albums: [Ranked] = []
        var songs: [Ranked] = []

        var isEmpty: Bool { songs.isEmpty }
    }

    struct FirstPlay: Equatable, Sendable {
        var date: Date
        var song: Ranked
    }

    var totals: [Period: Total] = [:]
    var tops: [Period: Top] = [:]
    /// The last 12 months, this one included, oldest first, zero-filled so the chart reads a quiet month
    /// as quiet rather than missing.
    var months: [Month] = []
    var currentStreak = 0
    var longestStreak = 0
    var daysListened = 0
    /// Plays per hour of the day, 0 to 23.
    var byHour = Array(repeating: 0, count: 24)
    /// Plays per weekday, Sunday first (`Calendar`'s weekday 1 at index 0).
    var byWeekday = Array(repeating: 0, count: 7)
    /// Old favorites gone quiet.
    var longTimeNoHear: [Ranked] = []
    var firstPlay: FirstPlay?
    /// Different songs ever played that are still in the library, and what share of it that is.
    var songsHeard = 0
    var libraryShare: Double?

    static let topCount = 5
    /// "Long time no hear": played at least this often, and not in this many days.
    static let missedPlays = 3
    static let quietDays = 180

    var isEmpty: Bool { total(.all).plays == 0 }

    func total(_ period: Period) -> Total { totals[period] ?? Total() }
    func top(_ period: Period) -> Top { tops[period] ?? Top() }

    var bestMonth: Month? {
        months.max { $0.plays < $1.plays }.flatMap { $0.plays > 0 ? $0 : nil }
    }

    /// 0 to 23, or nil before anything's played. Ties go to the earlier hour.
    var busiestHour: Int? { Self.busiest(byHour) }

    /// `Calendar` weekday, 1 (Sunday) to 7.
    var busiestWeekday: Int? { Self.busiest(byWeekday).map { $0 + 1 } }

    private static func busiest(_ counts: [Int]) -> Int? {
        guard let top = counts.max(), top > 0 else { return nil }
        return counts.firstIndex(of: top)
    }

    private struct Tally {
        var plays = 0
        var seconds: TimeInterval = 0
        var last = Int.min

        mutating func add(_ play: PlayRecord, seconds length: TimeInterval) {
            plays += 1
            seconds += length
            last = max(last, play.viewedAt)
        }
    }

    static func build(plays: [PlayRecord], songs: [String: SongFacts], libraryTrackCount: Int,
                      now: Date = .now, calendar: Calendar = .current) -> ListeningStats {
        var stats = ListeningStats()
        guard !plays.isEmpty else { return stats }

        // A song that's left the library has no length on record. It counts as an average song rather
        // than as nothing, so deleting an album doesn't shrink the hours.
        let known = songs.values.map(\.duration).filter { $0 > 0 }
        let averageLength = known.isEmpty ? 0 : known.reduce(0, +) / Double(known.count)
        func length(_ id: String) -> TimeInterval {
            if let duration = songs[id]?.duration, duration > 0 { return duration }
            return averageLength
        }

        let starts: [(Period, Int)] = Period.allCases.map { period in
            (period, period.start(now: now, calendar: calendar).map { Int($0.timeIntervalSince1970) } ?? Int.min)
        }
        let nowParts = calendar.dateComponents([.year, .month], from: now)
        let nowMonthIndex = (nowParts.year ?? 0) * 12 + (nowParts.month ?? 1)
        var tallies: [Period: [String: Tally]] = [:]
        var days = Set<Int>()
        var monthPlays = Array(repeating: 0, count: 12)
        var monthSeconds = Array(repeating: 0.0, count: 12)
        var first: PlayRecord?

        for play in plays {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: play.date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let seconds = length(play.trackID)
            days.insert(year * 10_000 + month * 100 + day)
            if let hour = parts.hour, (0..<24).contains(hour) { stats.byHour[hour] += 1 }
            if let weekday = parts.weekday, (1...7).contains(weekday) { stats.byWeekday[weekday - 1] += 1 }
            let monthsBack = nowMonthIndex - (year * 12 + month)
            if (0..<12).contains(monthsBack) {
                monthPlays[11 - monthsBack] += 1
                monthSeconds[11 - monthsBack] += seconds
            }
            for (period, start) in starts where play.viewedAt >= start {
                tallies[period, default: [:]][play.trackID, default: Tally()].add(play, seconds: seconds)
            }
            if play.viewedAt < first?.viewedAt ?? Int.max { first = play }
        }

        for period in Period.allCases {
            let songTallies = tallies[period] ?? [:]
            stats.totals[period] = Total(plays: songTallies.values.reduce(0) { $0 + $1.plays },
                                         seconds: songTallies.values.reduce(0) { $0 + $1.seconds },
                                         songs: songTallies.count,
                                         artists: Set(songTallies.keys.map { songs[$0]?.artist ?? "" }).count)
            stats.tops[period] = top(songTallies, songs: songs)
        }

        if let thisMonth = calendar.dateInterval(of: .month, for: now)?.start {
            stats.months = (0..<12).compactMap { index in
                calendar.date(byAdding: .month, value: index - 11, to: thisMonth).map {
                    Month(start: $0, plays: monthPlays[index], seconds: monthSeconds[index])
                }
            }
        }

        let activeDays = Set(days.compactMap { key in
            calendar.date(from: DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100))
        })
        stats.daysListened = activeDays.count
        (stats.currentStreak, stats.longestStreak) = streaks(activeDays, today: calendar.startOfDay(for: now), calendar: calendar)

        let allTime = tallies[.all] ?? [:]
        stats.songsHeard = allTime.keys.count { songs[$0]?.inLibrary ?? true }
        if libraryTrackCount > 0 {
            stats.libraryShare = min(1, Double(stats.songsHeard) / Double(libraryTrackCount))
        }
        stats.longTimeNoHear = missed(allTime, songs: songs, now: now)
        if let first {
            stats.firstPlay = FirstPlay(date: first.date, song: songItem(first.trackID, songs[first.trackID], plays: 1,
                                                                         seconds: length(first.trackID), last: first.viewedAt))
        }
        return stats
    }

    // MARK: - Pieces

    /// Days in a row with a play. The current streak may end yesterday: it isn't broken first thing in the
    /// morning before anything's on. (ShelfKit's rule for Mango and Earmark.)
    static func streaks(_ activeDays: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        var longest = 0
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        var current = 0
        var cursor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)
        while let day = cursor, activeDays.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return (current, longest)
    }

    private static func top(_ tallies: [String: Tally], songs: [String: SongFacts]) -> Top {
        var artists: [String: Ranked] = [:]
        var albums: [String: Ranked] = [:]
        var songItems: [Ranked] = []
        for (id, tally) in tallies {
            let facts = songs[id]
            songItems.append(songItem(id, facts, plays: tally.plays, seconds: tally.seconds, last: tally.last))
            let lastPlayed = Date(timeIntervalSince1970: TimeInterval(tally.last))
            let artist = facts?.artist ?? "Unknown Artist"
            var artistItem = artists[artist] ?? Ranked(id: artist, title: artist, plays: 0, seconds: 0)
            artistItem.plays += tally.plays
            artistItem.seconds += tally.seconds
            artistItem.lastPlayed = max(artistItem.lastPlayed ?? lastPlayed, lastPlayed)
            if artistItem.artistID == nil, let page = facts?.artistPageID {
                artistItem.artistID = page
                artistItem.thumb = facts?.artistThumb
            }
            artists[artist] = artistItem

            guard let facts, !facts.album.isEmpty else { continue }
            let albumArtist = facts.albumArtist ?? facts.artist
            let key = facts.albumID ?? "\(facts.album)\u{1F}\(albumArtist)"
            var albumItem = albums[key] ?? Ranked(id: key, title: facts.album, subtitle: albumArtist, thumb: facts.thumb,
                                                  plays: 0, seconds: 0, albumID: facts.albumID, artistID: facts.albumArtistID)
            albumItem.plays += tally.plays
            albumItem.seconds += tally.seconds
            albumItem.lastPlayed = max(albumItem.lastPlayed ?? lastPlayed, lastPlayed)
            albums[key] = albumItem
        }
        return Top(artists: ranked(Array(artists.values)), albums: ranked(Array(albums.values)), songs: ranked(songItems))
    }

    /// Most plays first; a tie goes to the more recent, then to the title.
    private static func ranked(_ items: [Ranked], limit: Int = topCount) -> [Ranked] {
        Array(items.sorted {
            ($0.plays, $0.lastPlayed ?? .distantPast, $1.title) > ($1.plays, $1.lastPlayed ?? .distantPast, $0.title)
        }.prefix(limit))
    }

    private static func songItem(_ id: String, _ facts: SongFacts?, plays: Int, seconds: TimeInterval, last: Int) -> Ranked {
        Ranked(id: id, title: facts?.title ?? "Unknown Song", subtitle: facts?.artist, thumb: facts?.thumb, plays: plays,
               seconds: seconds, lastPlayed: Date(timeIntervalSince1970: TimeInterval(last)),
               trackID: facts?.inLibrary == false ? nil : id, albumID: facts?.albumID, artistID: facts?.artistPageID)
    }

    /// Songs played at least `missedPlays` times and not for `quietDays`. Plex's own per-song count and
    /// last play (`viewCount`, `lastViewedAt`) go in too: they remember plays the history may have lost.
    private static func missed(_ tallies: [String: Tally], songs: [String: SongFacts], now: Date) -> [Ranked] {
        let quietSince = Int(now.timeIntervalSince1970) - quietDays * 86_400
        let items: [Ranked] = tallies.compactMap { id, tally in
            guard let facts = songs[id], facts.inLibrary else { return nil }
            let plays = max(tally.plays, facts.viewCount ?? 0)
            let last = max(tally.last, facts.lastViewedAt ?? Int.min)
            guard plays >= missedPlays, last < quietSince else { return nil }
            return songItem(id, facts, plays: plays, seconds: tally.seconds, last: last)
        }
        // The longest-lost first among equals.
        return Array(items.sorted {
            ($0.plays, $1.lastPlayed ?? .distantPast, $1.title) > ($1.plays, $0.lastPlayed ?? .distantPast, $0.title)
        }.prefix(topCount))
    }
}

/// How an update lines new history up with what's saved. History is read oldest first, so new plays
/// only ever append; anything else (a play deleted in Plex, one back-dated by an offline sync) means
/// reading it all again.
enum HistorySync {
    /// Where an update starts reading: one play early, so the overlap proves nothing moved.
    static func resumeIndex(cached: Int) -> Int { max(0, cached - 1) }

    /// The saved plays plus the new ones, or nil when the overlap doesn't line up.
    static func merge(cached: [PlayRecord], fetched: [PlayRecord], total: Int?) -> [PlayRecord]? {
        guard let last = cached.last else { return fetched }
        if let total, total < cached.count { return nil }
        guard fetched.first == last else { return nil }
        return cached + fetched.dropFirst()
    }

    /// Offsets of the pages after the first, for reading them side by side.
    static func pageStarts(after start: Int, size: Int, total: Int) -> [Int] {
        guard size > 0 else { return [] }
        return Array(stride(from: start + size, to: total, by: size))
    }
}
