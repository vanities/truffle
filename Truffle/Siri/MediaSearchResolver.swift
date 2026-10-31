import Foundation
import Intents

/// What someone asked Siri for, without SiriKit's types, so the matching is plain data to test.
struct MediaRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case any, song, album, artist, playlist
        /// Podcasts, audiobooks, radio, video: not Truffle's.
        case unsupported
    }

    var kind: Kind = .any
    var name: String?
    var artist: String?
    var album: String?
    var genres: [String] = []
    var moods: [String] = []
    var shuffled = false

    /// "Play some music" asks for nothing in particular.
    var isOpenEnded: Bool { name == nil && artist == nil && album == nil }
}

extension MediaRequest {
    init(_ search: INMediaSearch?, shuffled: Bool?) {
        self.init(kind: Self.kind(search?.mediaType ?? .unknown),
                  name: Self.text(search?.mediaName), artist: Self.text(search?.artistName), album: Self.text(search?.albumName),
                  genres: search?.genreNames ?? [], moods: search?.moodNames ?? [], shuffled: shuffled ?? false)
    }

    private static func kind(_ type: INMediaItemType) -> Kind {
        switch type {
        case .song: .song
        case .album: .album
        case .artist: .artist
        case .playlist: .playlist
        case .unknown, .music, .genre, .station, .musicStation, .algorithmicRadioStation: .any
        default: .unsupported
        }
    }

    private static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The library as Siri's matching sees it: the lists the app already holds, and the server's search
/// for songs (and anything the lists don't have).
@MainActor
protocol MediaCatalog: AnyObject {
    var playlists: [Playlist] { get }
    var albums: [Album] { get }
    var artists: [Artist] { get }
    func search(_ text: String, limit: Int) async throws -> SearchResults
}

extension MusicLibrary: MediaCatalog {}

/// Picks the one thing to play for a Siri request. The best-named match wins; on a tie, your own
/// playlists beat the mixes, then artists, albums and songs. A name that's a song plays on into its
/// album.
@MainActor
enum MediaSearchResolver {
    private static let likedNames = ["liked", "liked songs", "likes", "hearts", "hearted songs", "favorites", "favorite songs",
                                     "loved", "loved songs", "good stuff"].map(MediaText.key)
    private static let everythingNames = ["shuffle all", "everything", "all songs", "all music", "all my music", "music",
                                          "library", "songs", "anything", "something"].map(MediaText.key)

    private struct Candidate {
        let plan: PlaybackPlan
        let score: Int
        /// Lower wins a tie.
        let rank: Int
    }

    static func resolve(_ request: MediaRequest, in catalog: some MediaCatalog, mixes: [MixCatalog.Entry]) async -> PlaybackPlan? {
        if request.kind == .unsupported { return nil }
        let shuffleAll = mixes.first { $0.mix.kind == .shuffleAll }.map { PlaybackPlan.mix($0.mix, theme: $0.theme) }
        if request.isOpenEnded {
            let asked = request.genres + request.moods
            return asked.lazy.compactMap { bestMix(named: $0, in: mixes, minimum: 1)?.plan }.first ?? shuffleAll
        }
        if let name = request.name, request.kind == .any || request.kind == .playlist {
            let key = MediaText.key(name)
            if likedNames.contains(key), let liked = mixes.first(where: { $0.mix.kind == .liked }) {
                return .mix(liked.mix, theme: liked.theme)
            }
            if everythingNames.contains(key) { return shuffleAll }
        }

        var candidates = local(request, in: catalog, mixes: mixes)
        let best = candidates.map(\.score).max() ?? 0
        if best < 3 || request.kind == .song, let text = request.name ?? request.album ?? request.artist {
            candidates += await searched(text, request, in: catalog)
        }
        return candidates.max { ($0.score, -$0.rank) < ($1.score, -$1.rank) }?.plan
    }

    private static func local(_ request: MediaRequest, in catalog: some MediaCatalog, mixes: [MixCatalog.Entry]) -> [Candidate] {
        var found: [Candidate] = []
        let kind = request.kind
        if let name = request.name, request.artist == nil, kind == .any || kind == .playlist {
            found += catalog.playlists.map { Candidate(plan: .forPlaylist($0, shuffled: request.shuffled), score: MediaText.score($0.title, asked: name), rank: 0) }
            if let mix = bestMix(named: name, in: mixes, minimum: 2) { found.append(Candidate(plan: mix.plan, score: mix.score, rank: 1)) }
        }
        if let name = artistName(request) {
            found += catalog.artists.map { Candidate(plan: .artist($0), score: MediaText.score($0.title, asked: name), rank: 2) }
        }
        if let name = albumName(request) {
            found += catalog.albums.filter { matchesArtist($0.artist, request) }.map {
                Candidate(plan: .album($0, startAt: nil, shuffled: request.shuffled), score: MediaText.score($0.title, asked: name), rank: 3)
            }
        }
        return found.filter { $0.score > 0 }
    }

    /// The artist's name when the request is for an artist: "play Radiohead", "play some Radiohead".
    private static func artistName(_ request: MediaRequest) -> String? {
        switch request.kind {
        case .artist: request.name ?? request.artist
        // A name with an artist is a song or album by them, not the artist.
        case .any where request.album == nil:
            switch (request.name, request.artist) {
            case (let name?, nil): name
            case (nil, let artist?): artist
            default: nil
            }
        default: nil
        }
    }

    private static func albumName(_ request: MediaRequest) -> String? {
        request.kind == .any || request.kind == .album ? request.album ?? request.name : nil
    }

    private static func searched(_ text: String, _ request: MediaRequest, in catalog: some MediaCatalog) async -> [Candidate] {
        guard let results = try? await catalog.search(text, limit: 12) else { return [] }
        var found: [Candidate] = []
        if let name = artistName(request) {
            found += results.artists.map { Candidate(plan: .artist($0), score: MediaText.score($0.title, asked: name), rank: 2) }
        }
        if let name = albumName(request) {
            found += results.albums.filter { matchesArtist($0.artist, request) }.map {
                Candidate(plan: .album($0, startAt: nil, shuffled: request.shuffled), score: MediaText.score($0.title, asked: name), rank: 3)
            }
        }
        if let name = request.name, request.kind == .any || request.kind == .song {
            let onAlbum = { (track: Track) in request.album.map { MediaText.score(track.album, asked: $0) > 0 } ?? true }
            found += results.tracks.filter { matchesArtist($0.artist, request) && onAlbum($0) }
                .map { Candidate(plan: .forSong($0), score: MediaText.score($0.title, asked: name), rank: 4) }
        }
        return found.filter { $0.score > 0 }
    }

    /// "Play the Halloween mix", or "play some Christmas music": a mix by its title, its holiday or its
    /// season.
    private static func bestMix(named name: String, in mixes: [MixCatalog.Entry], minimum: Int) -> (plan: PlaybackPlan, score: Int)? {
        let scored = mixes.map { entry in
            var names = [entry.mix.title]
            // Today's season mix carries the moment's theme, so only a holiday's own mix answers to the
            // holiday's name.
            if let art = entry.mix.art, entry.mix.kind == .moment || entry.mix.kind == .season { names.append(spaced(art)) }
            if entry.mix.kind == .moment { names.append(entry.theme.title) }
            return (entry: entry, score: names.map { MediaText.score($0, asked: name) }.max() ?? 0)
        }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score >= minimum else { return nil }
        return (.mix(best.entry.mix, theme: best.entry.theme), best.score)
    }

    /// "fourthOfJuly" → "fourth Of July".
    private static func spaced(_ key: String) -> String {
        key.reduce(into: "") { text, character in
            if character.isUppercase { text.append(" ") }
            text.append(character)
        }
    }

    private static func matchesArtist(_ artist: String, _ request: MediaRequest) -> Bool {
        guard let wanted = request.artist else { return true }
        return MediaText.score(artist, asked: wanted) > 0
    }
}
