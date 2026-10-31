import Foundation
import os

/// Mood tag name → the key Plex filters by, per level. Albums carry most of the tagging; some songs
/// are tagged on their own.
struct MoodKeys: Sendable {
    var album: [String: String]
    var track: [String: String]
}

/// Where an endless shuffle draws from.
enum ShuffleFeed: Codable, Hashable, Sendable {
    case library
    /// A big playlist (a smart "All Music"), walked by position instead of downloaded whole.
    case playlist(id: String, total: Int)
}

extension MusicLibrary {
    func nextShuffled(_ count: Int, from feed: ShuffleFeed) async throws -> [Track] {
        switch feed {
        case .library:
            return try await nextShuffled(count)
        case .playlist(let id, let total):
            var walk = playlistWalks[id] ?? ShuffleWalk(total: total)
            let positions = walk.take(count)
            playlistWalks[id] = walk
            let found = try await withClient("playlist positions") { client in
                try await withThrowingTaskGroup(of: (Int, Track?).self) { group in
                    for (order, position) in positions.enumerated() {
                        group.addTask {
                            let container = try await client.get("/playlists/\(id)/items", PlexQuery().page(start: position, size: 1))
                            return (order, container.metadata.first.flatMap(Track.init))
                        }
                    }
                    var results: [(Int, Track?)] = []
                    for try await result in group { results.append(result) }
                    return results
                }
            }
            Logger.shuffle.info("[shuffle] playlist \(id, privacy: .public): \(walk.played)/\(walk.total) this round")
            return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    /// Next songs of the true shuffle. Saves the walk, so the round carries on after a relaunch.
    func nextShuffled(_ count: Int) async throws -> [Track] {
        if walk == nil, trackCount > 0 { walk = ShuffleWalk(total: trackCount) }
        guard var current = walk else { return [] }
        let positions = current.take(count)
        walk = current
        saveWalk()
        let tracks = try await tracks(atPositions: positions)
        Logger.shuffle.info("[shuffle] positions \(positions.map(String.init).joined(separator: ","), privacy: .public) → \(tracks.count) songs (round \(current.round), \(current.played)/\(current.total))")
        return tracks
    }

    /// A uniformly random album from the whole library.
    func randomAlbumTracks() async throws -> (Album, [Track])? {
        guard let album = albums.randomElement() else { return nil }
        Logger.mixes.info("[mixes] random album \(album.title, privacy: .public) of \(self.albums.count)")
        return (album, try await tracks(of: album))
    }

    func tracks(for mix: Mix, theme: SeasonTheme, now: Date = .now) async throws -> [Track] {
        let sw = Stopwatch()
        let tracks: [Track]
        switch mix.kind {
        case .shuffleAll: tracks = try await nextShuffled(5)
        case .randomAlbum: tracks = try await randomAlbumTracks()?.1 ?? []
        case .liked: tracks = try await likedTracks().shuffled()
        case .season: tracks = try await moodMix(SeasonCalendar.theme(season: theme.season).recipe)
        case .moment: tracks = try await moodMix(theme.recipe)
        case .nightDrive: tracks = try await moodMix(.nightDrive)
        case .lastYear: tracks = try await lastYearMix(now: now)
        case .seasonFavorites: tracks = try await seasonFavorites(theme.season, now: now)
        }
        Logger.mixes.info("[mixes] \(mix.title, privacy: .public): \(tracks.count) songs in \(sw.ms, format: .fixed(precision: 0))ms")
        return tracks
    }

    // MARK: - Moods

    func moodMix(_ recipe: MoodRecipe, limit: Int = 100) async throws -> [Track] {
        let keys = try await loadMoodKeys()
        async let primary = tracks(withMoods: recipe.primary, keys: keys, cap: 300)
        async let secondary = tracks(withMoods: recipe.secondary, keys: keys, cap: 300)
        let (main, fill) = try await (primary, secondary)
        Logger.mixes.info("[mixes] \(recipe.title, privacy: .public): \(main.count) primary + \(fill.count) secondary candidates")
        return MixBuilder.moodMix(primary: main, secondary: fill, limit: limit)
    }

    private func loadMoodKeys() async throws -> MoodKeys {
        if let moodKeys { return moodKeys }
        guard let section else { return MoodKeys(album: [:], track: [:]) }
        async let albumMoods = withClient("album moods") { try await $0.get("/library/sections/\(section.id)/mood", PlexQuery([("type", "9")])) }
        async let trackMoods = withClient("track moods") { try await $0.get("/library/sections/\(section.id)/mood", PlexQuery([("type", "10")])) }
        let (albums, tracks) = try await (albumMoods, trackMoods)
        let keys = MoodKeys(album: Dictionary(albums.directories.map { ($0.title, $0.key) }, uniquingKeysWith: { first, _ in first }),
                            track: Dictionary(tracks.directories.map { ($0.title, $0.key) }, uniquingKeysWith: { first, _ in first }))
        moodKeys = keys
        Logger.mixes.info("[mixes] \(keys.album.count) album moods, \(keys.track.count) song moods")
        return keys
    }

    /// Songs whose album, or the song itself, carries any of `moods`. `sort=random` samples a big
    /// set instead of taking its alphabetical first page.
    private func tracks(withMoods moods: [String], keys: MoodKeys, cap: Int) async throws -> [Track] {
        guard let section, !moods.isEmpty else { return [] }
        let albumKeys = moods.compactMap { keys.album[$0] }
        let trackKeys = moods.compactMap { keys.track[$0] }
        let path = "/library/sections/\(section.id)/all"
        var found: [Track] = []
        if !albumKeys.isEmpty {
            found += try await withClient("album mood songs") {
                try await $0.get(path, PlexQuery([("type", "10"), ("album.mood", albumKeys.joined(separator: ",")), ("sort", "random")])
                    .page(start: 0, size: cap))
            }.metadata.compactMap(Track.init)
        }
        if !trackKeys.isEmpty {
            found += try await withClient("song mood songs") {
                try await $0.get(path, PlexQuery([("type", "10"), ("mood", trackKeys.joined(separator: ",")), ("sort", "random")])
                    .page(start: 0, size: cap))
            }.metadata.compactMap(Track.init)
        }
        return found
    }

    // MARK: - History

    /// What was played two weeks either side of today's date, in earlier years.
    func lastYearMix(now: Date = .now, limit: Int = 100) async throws -> [Track] {
        let earliest = try await earliestPlayDate()
        let windows = HistoryWindows.aroundThisDate(now, earliest: earliest)
        let plays = try await playedIDs(in: windows)
        let ids = Array(MixBuilder.distinct(plays).shuffled().prefix(limit))
        Logger.mixes.info("[mixes] this time last year: \(windows.count) window(s), \(plays.count) plays, \(ids.count) songs")
        return try await details(for: ids)
    }

    /// The songs played most in this season in earlier years.
    func seasonFavorites(_ season: Season, now: Date = .now, limit: Int = 60) async throws -> [Track] {
        let earliest = try await earliestPlayDate()
        let windows = HistoryWindows.seasonWindows(season, southern: settings.isSouthern, before: now, earliest: earliest)
        let plays = try await playedIDs(in: windows)
        let ids = MixBuilder.favorites(plays: plays, limit: limit)
        Logger.mixes.info("[mixes] \(season.title, privacy: .public) favorites: \(windows.count) window(s), \(plays.count) plays, top \(ids.count)")
        return try await details(for: ids).shuffled()
    }

    private func earliestPlayDate() async throws -> Date {
        if let earliestPlay { return earliestPlay }
        guard let section else { return .now }
        let container = try await withClient("first play") {
            try await $0.get("/status/sessions/history/all",
                             PlexQuery([("librarySectionID", section.id), ("sort", "viewedAt:asc")]).page(start: 0, size: 1))
        }
        let first = container.metadata.first?.viewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .now
        earliestPlay = first
        Logger.mixes.info("[mixes] history starts \(first.formatted(date: .abbreviated, time: .omitted), privacy: .public)")
        return first
    }

    /// Song ids played in the windows, one entry per play.
    private func playedIDs(in windows: [DateInterval]) async throws -> [String] {
        guard let section else { return [] }
        var ids: [String] = []
        for window in windows {
            // `viewedAt>` + `=…` is Plex's `viewedAt>=…` (see PlexQuery).
            let query = PlexQuery([
                ("librarySectionID", section.id),
                ("viewedAt>", String(Int(window.start.timeIntervalSince1970))),
                ("viewedAt<", String(Int(window.end.timeIntervalSince1970))),
                ("sort", "viewedAt:desc"),
            ]).page(start: 0, size: 2000)
            let container = try await withClient("history") { try await $0.get("/status/sessions/history/all", query) }
            ids += container.metadata.filter { $0.type == nil || $0.type == "track" }.map(\.ratingKey).filter { !$0.isEmpty }
        }
        return ids
    }
}
