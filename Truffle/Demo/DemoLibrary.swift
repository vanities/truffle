import Foundation

/// The invented library in scripts/demo-catalog.json, described the way Plex Media Server describes
/// music. A port of the `Library` class in scripts/demo_server.py; keep the two in step.
struct DemoLibrary: Sendable {
    struct Artist: Sendable {
        let id: String
        let name: String
        let portrait: String
        let albumCount: Int
        /// From the history, as PMS reports them on artists.
        var viewCount: Int?
        var lastViewedAt: Int?
    }

    struct Album: Sendable {
        let id: String
        let title: String
        let artistID: String
        let artistName: String
        let year: Int
        let cover: String
        let moods: [String]
        let trackCount: Int
        let addedAt: Int
        /// The newest play of any of its songs, like Plex's album `lastViewedAt`.
        var lastViewedAt: Int?
    }

    struct Track: Sendable {
        let id: String
        let title: String
        let artistID: String
        let artistName: String
        let albumID: String
        let albumTitle: String
        let albumYear: Int
        let index: Int
        /// Which bundled song (audio/song-N.m4a) plays for this track.
        let song: Int
        let addedAt: Int
        let loudness: Double
        let gain: Double
        let albumGain: Double
        var userRating: Double?
        var lastRatedAt: Int?
        /// From the history, as Plex reports them on songs.
        var viewCount: Int?
        var lastViewedAt: Int?

        var durationMS: Int { DemoLibrary.songLengths[song] * 1000 }
    }

    struct Playlist: Sendable {
        /// A slot, with its own id like PMS's playlistItemID, which removing and moving go by.
        struct Entry: Sendable, Equatable {
            let itemID: Int
            let trackID: String
        }

        let id: String
        var title: String
        let smart: Bool
        /// nil for the smart "All Music" playlist, which holds every song.
        var entries: [Entry]?
        var summary: String?
        /// A bundled poster, relative to the DemoLibrary folder.
        var poster: String?
        /// A cover uploaded through `/library/metadata/<id>/posters`, and its stamp for the thumb path.
        var uploadedPoster: Data?
        var posterStamp: Int?
        let addedAt: Int
        var updatedAt: Int

        var items: [String]? { entries?.map(\.trackID) }
    }

    struct Play: Sendable {
        let trackID: String
        let viewedAt: Int
    }

    /// Not "demo", which is what scripts/demo_server.py answers: the two libraries differ, and each
    /// keeps its own saved snapshot.
    static let machineIdentifier = "truffle-demo"
    static let section = "1"
    static let stamp = 1_780_000_000
    /// Lengths of the bundled songs, DemoLibrary/audio/song-N.m4a, in seconds.
    static let songLengths = [151, 185, 222, 204, 168, 239]

    private(set) var artists: [Artist] = []
    private(set) var albums: [Album] = []
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    private var nextItemID = 1
    private(set) var moods: [(name: String, key: String)] = []
    private(set) var history: [Play] = []
    private var trackPositions: [String: Int] = [:]
    private var albumPositions: [String: Int] = [:]
    private var artistPositions: [String: Int] = [:]

    init(catalogURL: URL, now: Date = .now, calendar: Calendar = .current) throws {
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
        var rng = SeededGenerator(seed: 42)
        var moodKeys: [String: String] = [:]
        for (artistIndex, artist) in catalog.artists.enumerated() {
            let artistID = String(1000 + artistIndex)
            artists.append(Artist(id: artistID, name: artist.name, portrait: "artists/\(Self.slug(artist.name)).jpg",
                                  albumCount: artist.albums.count))
            for album in artist.albums {
                let albumID = String(2000 + albums.count)
                for mood in album.moods where moodKeys[mood] == nil {
                    let key = String(5000 + moods.count)
                    moodKeys[mood] = key
                    moods.append((mood, key))
                }
                let added = Self.stamp + album.year * 1000 + Int.random(in: 0...900, using: &rng)
                albums.append(Album(id: albumID, title: album.title, artistID: artistID, artistName: artist.name, year: album.year,
                                    cover: "covers/\(Self.slug(album.title)).jpg", moods: album.moods,
                                    trackCount: album.tracks.count, addedAt: added))
                let albumLoudness = Double.random(in: -15.5 ... -8.5, using: &rng)
                for (offset, title) in album.tracks.enumerated() {
                    let song = Int.random(in: 0..<Self.songLengths.count, using: &rng)
                    let loudness = albumLoudness + Double.random(in: -2.5...1.5, using: &rng)
                    tracks.append(Track(id: String(3000 + tracks.count), title: title, artistID: artistID, artistName: artist.name,
                                        albumID: albumID, albumTitle: album.title, albumYear: album.year, index: offset + 1,
                                        song: song, addedAt: added, loudness: Self.rounded(loudness),
                                        gain: Self.rounded(-24.5 - loudness), albumGain: Self.rounded(-24.5 - albumLoudness)))
                }
            }
        }
        // Every seventh song is loved, like a lived-in library.
        for position in stride(from: 0, to: tracks.count, by: 7) {
            tracks[position].userRating = 10
            tracks[position].lastRatedAt = Self.stamp + Int.random(in: 0...10_000_000, using: &rng)
        }
        trackPositions = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
        albumPositions = Dictionary(uniqueKeysWithValues: albums.enumerated().map { ($1.id, $0) })
        artistPositions = Dictionary(uniqueKeysWithValues: artists.enumerated().map { ($1.id, $0) })
        history = makeHistory(now: now, calendar: calendar, rng: &rng)
        var lastPlayed: [String: Int] = [:]
        var artistPlays: [String: (count: Int, last: Int)] = [:]
        for play in history {
            guard let position = trackPositions[play.trackID] else { continue }
            tracks[position].viewCount = (tracks[position].viewCount ?? 0) + 1
            tracks[position].lastViewedAt = max(tracks[position].lastViewedAt ?? 0, play.viewedAt)
            lastPlayed[tracks[position].albumID] = max(lastPlayed[tracks[position].albumID] ?? 0, play.viewedAt)
            let before = artistPlays[tracks[position].artistID] ?? (0, 0)
            artistPlays[tracks[position].artistID] = (before.count + 1, max(before.last, play.viewedAt))
        }
        for position in albums.indices { albums[position].lastViewedAt = lastPlayed[albums[position].id] }
        for position in artists.indices {
            artists[position].viewCount = artistPlays[artists[position].id]?.count
            artists[position].lastViewedAt = artistPlays[artists[position].id]?.last
        }

        let byTitle = Dictionary(tracks.map { ($0.title, $0.id) }, uniquingKeysWith: { _, last in last })
        let long = Self.stamp - 60 * 86_400
        playlists = [Playlist(id: "900", title: "All Music", smart: true, entries: nil, addedAt: long, updatedAt: long)]
        let year = calendar.component(.year, from: now)
        for (offset, playlist) in catalog.playlists.enumerated() {
            var made = Playlist(id: String(901 + offset), title: playlist.title, smart: false,
                                entries: makeEntries(playlist.pick.compactMap { byTitle[$0] }), summary: playlist.summary,
                                poster: playlist.poster, addedAt: long, updatedAt: Self.stamp - offset * 9 * 86_400)
            Self.moveMixTag(of: &made, to: year)
            playlists.append(made)
        }
    }

    func track(_ id: String) -> Track? { trackPositions[id].map { tracks[$0] } }
    func album(_ id: String) -> Album? { albumPositions[id].map { albums[$0] } }
    func artist(_ id: String) -> Artist? { artistPositions[id].map { artists[$0] } }
    func trackPosition(_ id: String) -> Int? { trackPositions[id] }

    func playlistTracks(_ playlist: Playlist) -> [Track] {
        playlistEntries(playlist).map(\.track)
    }

    /// (playlistItemID, song) per slot; the smart "All Music" numbers every song in order.
    func playlistEntries(_ playlist: Playlist) -> [(itemID: Int, track: Track)] {
        guard let entries = playlist.entries else { return tracks.enumerated().map { ($0.offset + 1, $0.element) } }
        return entries.compactMap { entry in track(entry.trackID).map { (entry.itemID, $0) } }
    }

    func playlistIndex(_ id: String) -> Int? { playlists.firstIndex { $0.id == id } }

    /// New slots for songs added to a playlist, numbered on from the last.
    mutating func makeEntries(_ trackIDs: [String]) -> [Playlist.Entry] {
        defer { nextItemID += trackIDs.count }
        return trackIDs.enumerated().map { Playlist.Entry(itemID: nextItemID + $0.offset, trackID: $0.element) }
    }

    /// The image file for an artist, album or playlist id, relative to the DemoLibrary folder.
    func artwork(for id: String) -> String? {
        if let poster = playlists.first(where: { $0.id == id })?.poster { return poster }
        return album(id)?.cover ?? artist(id)?.portrait
    }

    // MARK: - History

    /// Listening sessions from March 2024 up to now, in the phone's time zone: the drive in, lunch, the
    /// drive home and evenings on weekdays, lazier weekends. A few songs or most of an album at a time,
    /// each song played mostly in the seasons its album's moods suit. Mirrors `_make_history` in
    /// scripts/demo_server.py (the numbers differ: different random generators).
    private func makeHistory(now: Date, calendar: Calendar, rng: inout SeededGenerator) -> [Play] {
        let seasons: [String: Set<Int>] = [
            "Autumnal": [9, 10, 11], "Spooky": [10], "Eerie": [10, 11], "Nostalgic": [9, 10, 11],
            "Wintry": [12, 1, 2], "Cold": [12, 1, 2], "Ethereal": [12, 1, 2], "Summery": [6, 7, 8],
            "Carefree": [6, 7, 8], "Springlike": [3, 4, 5], "Pastoral": [3, 4, 5], "Romantic": [2],
        ]
        func suits(_ track: Track, _ month: Int) -> Bool {
            let months = Set((album(track.albumID)?.moods ?? []).flatMap { seasons[$0] ?? [] })
            return months.isEmpty || months.contains(month)
        }
        let byAlbum = Dictionary(grouping: tracks, by: \.albumID)
        let albumSongs = albums.compactMap { byAlbum[$0.id] }
        // (hour, chance of a session starting around then)
        let weekday: [(Double, Double)] = [(7.6, 0.4), (12.3, 0.12), (17.4, 0.35), (21.0, 0.3)]
        let weekend: [(Double, Double)] = [(10.8, 0.35), (15.0, 0.3), (20.5, 0.3)]
        guard var day = calendar.date(from: DateComponents(year: 2024, month: 3, day: 1)), !tracks.isEmpty else { return [] }
        let today = calendar.startOfDay(for: now)
        var plays: [Play] = []
        while day <= today {
            let month = calendar.component(.month, from: day)
            let slots = calendar.isDateInWeekend(day) ? weekend : weekday
            for (hour, chance) in slots {
                guard Double.random(in: 0..<1, using: &rng) < chance else { continue }
                var session: [Track] = []
                if Double.random(in: 0..<1, using: &rng) < 0.3 {
                    let fitting = albumSongs.filter { suits($0[0], month) }
                    guard !fitting.isEmpty else { continue }
                    let songs = fitting[Int.random(in: 0..<fitting.count, using: &rng)]
                    session = Array(songs.prefix(Int.random(in: min(3, songs.count)...songs.count, using: &rng)))
                } else {
                    for _ in 0..<Int.random(in: 2...5, using: &rng) {
                        var pick = tracks[Int.random(in: 0..<tracks.count, using: &rng)]
                        for _ in 0..<11 where !suits(pick, month) {
                            pick = tracks[Int.random(in: 0..<tracks.count, using: &rng)]
                        }
                        session.append(pick)
                    }
                }
                var moment = day.addingTimeInterval((hour + Double.random(in: -1...1, using: &rng)) * 3600)
                for track in session {
                    moment.addTimeInterval(TimeInterval(track.durationMS) / 1000)
                    if moment > now { break }
                    plays.append(Play(trackID: track.id, viewedAt: Int(moment.timeIntervalSince1970)))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return plays.sorted { $0.viewedAt < $1.viewedAt }
    }

    // MARK: - Helpers

    /// The seasonal-mix tag (`truffle-mix:halloween:2026`) and the title's year follow the calendar, so
    /// the curated mix shows up as this year's in any year.
    private static func moveMixTag(of playlist: inout Playlist, to year: Int) {
        guard let summary = playlist.summary,
              let match = summary.firstMatch(of: #/truffle-mix:[a-z]+:(\d{4})/#) else { return }
        let old = String(match.1)
        playlist.summary = summary.replacingOccurrences(of: old, with: String(year))
        playlist.title = playlist.title.replacingOccurrences(of: old, with: String(year))
    }

    /// The file names make-demo-covers.swift gives covers and portraits (NFKD, ASCII, dashes), like
    /// demo_server.py's `slug`.
    static func slug(_ text: String) -> String {
        let ascii = String(String.UnicodeScalarView(text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)))
        return ascii.lowercased()
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .joined(separator: "-")
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    private struct Catalog: Decodable {
        struct Artist: Decodable {
            let name: String
            let albums: [Album]
        }

        struct Album: Decodable {
            let title: String
            let year: Int
            let moods: [String]
            let tracks: [String]
        }

        struct Playlist: Decodable {
            let title: String
            let summary: String?
            let poster: String?
            let pick: [String]
        }

        let artists: [Artist]
        let playlists: [Playlist]
    }
}

/// SplitMix64: the demo library comes out the same on every launch.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
