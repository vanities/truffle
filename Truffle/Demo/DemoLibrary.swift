import Foundation

/// The invented library in scripts/demo-catalog.json, described the way Plex Media Server describes
/// music. A port of the `Library` class in scripts/demo_server.py; keep the two in step.
struct DemoLibrary: Sendable {
    struct Artist: Sendable {
        let id: String
        let name: String
        let portrait: String
        let albumCount: Int
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

        var durationMS: Int { DemoLibrary.songLengths[song] * 1000 }
    }

    struct Playlist: Sendable {
        let id: String
        var title: String
        let smart: Bool
        /// nil for the smart "All Music" playlist, which holds every song.
        var items: [String]?
        var summary: String?
        var poster: String?
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
        for play in history {
            guard let albumID = track(play.trackID)?.albumID else { continue }
            lastPlayed[albumID] = max(lastPlayed[albumID] ?? 0, play.viewedAt)
        }
        for position in albums.indices { albums[position].lastViewedAt = lastPlayed[albums[position].id] }

        let byTitle = Dictionary(tracks.map { ($0.title, $0.id) }, uniquingKeysWith: { _, last in last })
        playlists = [Playlist(id: "900", title: "All Music", smart: true, items: nil)]
        let year = calendar.component(.year, from: now)
        for (offset, playlist) in catalog.playlists.enumerated() {
            var made = Playlist(id: String(901 + offset), title: playlist.title, smart: false,
                                items: playlist.pick.compactMap { byTitle[$0] }, summary: playlist.summary, poster: playlist.poster)
            Self.moveMixTag(of: &made, to: year)
            playlists.append(made)
        }
    }

    func track(_ id: String) -> Track? { trackPositions[id].map { tracks[$0] } }
    func album(_ id: String) -> Album? { albumPositions[id].map { albums[$0] } }
    func artist(_ id: String) -> Artist? { artistPositions[id].map { artists[$0] } }
    func trackPosition(_ id: String) -> Int? { trackPositions[id] }

    func playlistTracks(_ playlist: Playlist) -> [Track] {
        guard let ids = playlist.items else { return tracks }
        return ids.compactMap(track)
    }

    /// The image file for an artist, album or playlist id, relative to the DemoLibrary folder.
    func artwork(for id: String) -> String? {
        if let poster = playlists.first(where: { $0.id == id })?.poster { return poster }
        return album(id)?.cover ?? artist(id)?.portrait
    }

    // MARK: - History

    /// ~900 plays over the last 32 months (plus a handful this week), each song played mostly in the
    /// seasons its album's moods suit. Relative to `now`, so "This Time Last Year" always has something.
    private func makeHistory(now: Date, calendar: Calendar, rng: inout SeededGenerator) -> [Play] {
        let seasons: [String: Set<Int>] = [
            "Autumnal": [9, 10, 11], "Spooky": [10], "Eerie": [10, 11], "Nostalgic": [9, 10, 11],
            "Wintry": [12, 1, 2], "Cold": [12, 1, 2], "Ethereal": [12, 1, 2], "Summery": [6, 7, 8],
            "Carefree": [6, 7, 8], "Springlike": [3, 4, 5], "Pastoral": [3, 4, 5], "Romantic": [2],
        ]
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .month, value: -32, to: today),
              let days = calendar.dateComponents([.day], from: start, to: today).day, days > 0 else { return [] }
        var plays: [Play] = []
        func play(_ track: Track, on day: Date, rng: inout SeededGenerator) {
            let hour = Int.random(in: 7...23, using: &rng)
            let minute = Int.random(in: 0...59, using: &rng)
            guard let moment = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), moment <= now else { return }
            plays.append(Play(trackID: track.id, viewedAt: Int(moment.timeIntervalSince1970)))
        }
        for _ in 0..<900 {
            let track = tracks[Int.random(in: 0..<tracks.count, using: &rng)]
            let months = Set((album(track.albumID)?.moods ?? []).flatMap { seasons[$0] ?? [] })
            var day = start
            for _ in 0..<12 {
                day = calendar.date(byAdding: .day, value: Int.random(in: 0..<days, using: &rng), to: start) ?? start
                if months.isEmpty || months.contains(calendar.component(.month, from: day)) { break }
            }
            play(track, on: day, rng: &rng)
        }
        for _ in 0..<24 {
            let track = tracks[Int.random(in: 0..<tracks.count, using: &rng)]
            let day = calendar.date(byAdding: .day, value: -Int.random(in: 0...6, using: &rng), to: today) ?? today
            play(track, on: day, rng: &rng)
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
