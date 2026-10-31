import Foundation
import os

struct SearchResults: Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var tracks: [Track] = []

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }
}

extension MusicLibrary {
    func albums(of artist: Artist) async throws -> [Album] {
        try await withClient("artist albums") { try await $0.get("/library/metadata/\(artist.id)/children") }
            .metadata.compactMap(Album.init)
    }

    func tracks(of album: Album) async throws -> [Track] {
        try await withClient("album tracks") { try await $0.get("/library/metadata/\(album.id)/children") }
            .metadata.compactMap(Track.init)
    }

    /// Every song by an artist, across albums.
    func tracks(of artist: Artist) async throws -> [Track] {
        try await withClient("artist tracks") { try await $0.get("/library/metadata/\(artist.id)/allLeaves") }
            .metadata.compactMap(Track.init)
    }

    func tracks(of playlist: Playlist, start: Int = 0, size: Int = 500) async throws -> [Track] {
        try await withClient("playlist items") {
            try await $0.get("/playlists/\(playlist.id)/items", PlexQuery().page(start: start, size: size))
        }.metadata.compactMap(Track.init)
    }

    func likedTracks(limit: Int = 500) async throws -> [Track] {
        guard let section else { return [] }
        return try await withClient("liked") {
            try await $0.get("/library/sections/\(section.id)/all",
                             PlexQuery([("type", "10"), ("userRating>", "8"), ("sort", "lastRatedAt:desc")]).page(start: 0, size: limit))
        }.metadata.compactMap(Track.init)
    }

    func search(_ text: String) async throws -> SearchResults {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let section else { return SearchResults() }
        let sw = Stopwatch()
        let container = try await withClient("search") {
            try await $0.get("/hubs/search", PlexQuery([("query", query), ("limit", "12"), ("sectionId", section.id)]))
        }
        var results = SearchResults()
        for hub in container.hubs {
            // The hub search spans every library; keep this one's.
            let items = hub.metadata.filter { $0.librarySectionID == nil || $0.librarySectionID == section.id }
            switch hub.type {
            case "artist": results.artists = items.compactMap(Artist.init)
            case "album": results.albums = items.compactMap(Album.init)
            case "track": results.tracks = items.compactMap(Track.init)
            default: continue
            }
        }
        Logger.library.info("[search] \(query.count) chars → \(results.artists.count)/\(results.albums.count)/\(results.tracks.count) in \(sw.ms, format: .fixed(precision: 0))ms")
        return results
    }

    /// Full metadata for songs (list endpoints leave out the loudness analysis), in the order asked.
    func details(for ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: Track] = [:]
        for batch in stride(from: 0, to: ids.count, by: 40).map({ Array(ids[$0..<min($0 + 40, ids.count)]) }) {
            let container = try await withClient("details") { try await $0.get("/library/metadata/\(batch.joined(separator: ","))") }
            for track in container.metadata.compactMap(Track.init) { byID[track.id] = track }
        }
        return ids.compactMap { byID[$0] }
    }

    /// The song at a position in the library sorted by id: how the true shuffle turns its random
    /// positions into songs without downloading the whole list.
    func tracks(atPositions positions: [Int]) async throws -> [Track] {
        guard let section, !positions.isEmpty else { return [] }
        let path = "/library/sections/\(section.id)/all"
        let found = try await withClient("positions") { client in
            try await withThrowingTaskGroup(of: (Int, Track?).self) { group in
                for (order, position) in positions.enumerated() {
                    group.addTask {
                        let container = try await client.get(path, PlexQuery([("type", "10"), ("sort", "id")]).page(start: position, size: 1))
                        return (order, container.metadata.first.flatMap(Track.init))
                    }
                }
                var results: [(Int, Track?)] = []
                for try await result in group { results.append(result) }
                return results
            }
        }
        return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
    }

    /// This year's skill-made playlist for a mix's theme ("halloween", "fall"…), if there is one.
    func curatedPlaylist(for mix: Mix, year: Int = Calendar.current.component(.year, from: .now)) -> Playlist? {
        guard mix.kind == .moment || mix.kind == .season, let theme = mix.art?.lowercased() else { return nil }
        return playlists.first { $0.mixTag?.theme == theme && $0.mixTag?.year == year }
    }

    func allTracks(of playlist: Playlist) async throws -> [Track] {
        var all: [Track] = []
        while all.count < playlist.trackCount {
            let page = try await tracks(of: playlist, start: all.count, size: 500)
            if page.isEmpty { break }
            all += page
        }
        return all
    }

    func artist(id: String) -> Artist? { artists.first { $0.id == id } }

    func album(id: String) -> Album? { albums.first { $0.id == id } ?? recentlyAdded.first { $0.id == id } }

    func albumArtist(for album: Album) -> Artist? {
        album.artistID.flatMap(artist(id:)) ?? artists.first { $0.title == album.artist }
    }
}
