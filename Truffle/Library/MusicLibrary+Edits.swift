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
        try await withClient("playlist add") {
            try await $0.send("PUT", "/playlists/\(playlist.id)/items", PlexQuery([("uri", itemsURI(tracks))]))
        }
        Logger.library.info("[library] added \(tracks.count) song(s) to \(playlist.title, privacy: .public)")
        await refreshPlaylists()
    }

    func createPlaylist(named title: String, with tracks: [Track]) async throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !tracks.isEmpty else { return }
        try await withClient("playlist create") {
            try await $0.send("POST", "/playlists", PlexQuery([("type", "audio"), ("title", name), ("smart", "0"),
                                                              ("uri", itemsURI(tracks))]))
        }
        Logger.library.info("[library] created playlist \(name, privacy: .public) with \(tracks.count) song(s)")
        await refreshPlaylists()
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
