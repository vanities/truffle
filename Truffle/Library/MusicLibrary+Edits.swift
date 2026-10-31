import Foundation
import os

extension MusicLibrary {
    /// Loves a song (a 10, Plexamp's love) or clears its rating. Returns the song as it now is.
    @discardableResult
    func setLiked(_ track: Track, _ liked: Bool) async throws -> Track {
        let rating = liked ? "10" : "-1"
        try await withClient("rate") {
            try await $0.send("PUT", "/:/rate", PlexQuery([("key", track.id), ("identifier", "com.plexapp.plugins.library"),
                                                           ("rating", rating)]))
        }
        var updated = track
        updated.userRating = liked ? 10 : nil
        Logger.library.info("[library] \(liked ? "liked" : "unliked", privacy: .public) \(track.title, privacy: .public)")
        noteRatingChanged(updated, wasLiked: isLiked(track))
        return updated
    }

    func add(_ tracks: [Track], to playlist: Playlist) async throws {
        guard !tracks.isEmpty, !playlist.isSmart else { return }
        try await appendSongs(tracks, to: playlist.id)
        await refreshPlaylists()
    }

    /// Appends songs to the end of a playlist, in order.
    func appendSongs(_ tracks: [Track], to playlistID: String) async throws {
        guard !tracks.isEmpty else { return }
        let sw = Stopwatch()
        try await withClient("playlist add") {
            try await $0.send("PUT", "/playlists/\(playlistID)/items", PlexQuery([("uri", itemsURI(tracks))]))
        }
        notePlaylistChanged(playlistID)
        Logger.library.info("[playlist] added \(tracks.count) song(s) to \(playlistID, privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    /// Makes a playlist of these songs, in this order, and returns it as Plex describes it in the answer.
    func createPlaylist(named title: String, with tracks: [Track]) async throws -> Playlist {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistEditError.needsName }
        guard !tracks.isEmpty else { throw PlaylistEditError.needsSongs }
        let sw = Stopwatch()
        let container = try await withClient("playlist create") {
            try await $0.container("POST", "/playlists", PlexQuery([("type", "audio"), ("title", name), ("smart", "0"),
                                                                   ("uri", itemsURI(tracks))]))
        }
        guard let made = container.metadata.first.flatMap(Playlist.init) else {
            Logger.library.error("[playlist] create answered without a playlist (\(container.metadata.count) items)")
            throw PlexError.decoding(path: "/playlists")
        }
        Logger.library.info("[playlist] created \(made.id, privacy: .public) \(name, privacy: .public) with \(tracks.count) song(s) in \(sw.ms, format: .fixed(precision: 0))ms")
        return made
    }

    func renamePlaylist(_ playlistID: String, to title: String) async throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistEditError.needsName }
        try await withClient("playlist rename") {
            try await $0.send("PUT", "/playlists/\(playlistID)", PlexQuery([("title", name)]))
        }
        Logger.library.info("[playlist] renamed \(playlistID, privacy: .public) to \(name, privacy: .public)")
    }

    /// Plex keeps a playlist's description in two places, and scripts/plex_mix.py (checked on PMS 1.43)
    /// sets both: the metadata item's, locked so a refresh doesn't clear it, and the playlist's own.
    func setPlaylistSummary(_ playlistID: String, _ summary: String) async throws {
        let sw = Stopwatch()
        try await withClient("playlist summary") { client in
            try await client.send("PUT", "/library/metadata/\(playlistID)",
                                  PlexQuery([("summary.value", summary), ("summary.locked", "1")]))
            try await client.send("PUT", "/playlists/\(playlistID)", PlexQuery([("summary", summary)]))
        }
        Logger.library.info("[playlist] summary of \(playlistID, privacy: .public) set (\(summary.count) chars) in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    /// The JPEG itself is the body. Plex serves it as the playlist's `thumb` from then on.
    func uploadPlaylistCover(_ playlistID: String, jpeg: Data) async throws {
        let sw = Stopwatch()
        try await withClient("playlist cover") {
            try await $0.send("POST", "/library/metadata/\(playlistID)/posters", body: jpeg, contentType: "image/jpeg")
        }
        Logger.library.info("[playlist] cover for \(playlistID, privacy: .public) uploaded (\(jpeg.count)B) in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    func removeFromPlaylist(_ playlistID: String, itemID: Int) async throws {
        try await withClient("playlist remove") {
            try await $0.send("DELETE", "/playlists/\(playlistID)/items/\(itemID)")
        }
        notePlaylistChanged(playlistID)
        Logger.library.debug("[playlist] removed item \(itemID) from \(playlistID, privacy: .public)")
    }

    /// Puts a slot right after another one, or first when `after` is nil.
    func movePlaylistItem(_ playlistID: String, itemID: Int, after: Int?) async throws {
        let query = after.map { PlexQuery([("after", String($0))]) } ?? PlexQuery()
        try await withClient("playlist move") {
            try await $0.send("PUT", "/playlists/\(playlistID)/items/\(itemID)/move", query)
        }
        notePlaylistChanged(playlistID)
        Logger.library.debug("[playlist] moved item \(itemID) after \(after.map(String.init) ?? "the top", privacy: .public) in \(playlistID, privacy: .public)")
    }

    func refreshPlaylists() async {
        do {
            let container = try await withClient("playlists") { try await $0.get("/playlists", PlexQuery([("playlistType", "audio")])) }
            playlistsChanged(container.metadata.compactMap(Playlist.init))
        } catch {
            Logger.library.error("[library] playlists refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Plex adds library items to a playlist by URI: `server://<machine>/com.plexapp.plugins.library/library/metadata/<ids>`.
    private func itemsURI(_ tracks: [Track]) -> String {
        "server://\(server?.machineIdentifier ?? "")/com.plexapp.plugins.library/library/metadata/"
            + tracks.map(\.id).joined(separator: ",")
    }
}

enum PlaylistEditError: LocalizedError, Equatable {
    case needsName
    case needsSongs

    var errorDescription: String? {
        switch self {
        case .needsName: "A playlist needs a name."
        case .needsSongs: "A new playlist needs a song or two."
        }
    }
}
