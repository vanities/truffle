import Foundation
import os

/// What the playlist editor holds until Save: a new playlist, or changes to one of yours.
struct PlaylistDraft: Identifiable, Hashable, Sendable {
    struct Song: Identifiable, Hashable, Sendable {
        let id: UUID
        let track: Track
        /// The slot's `playlistItemID` for songs already in the playlist; nil for ones picked here.
        let itemID: Int?

        init(track: Track, itemID: Int? = nil) {
            id = UUID()
            self.track = track
            self.itemID = itemID
        }
    }

    let id: UUID
    /// nil for a new playlist.
    let original: Playlist?
    var title: String
    var summary: String
    var songs: [Song]
    /// A new cover, already squared and JPEG'd by `CoverImage`.
    var cover: Data?
    /// Open the playlist once it's made (Library → Playlists' "+" does).
    var opensWhenSaved: Bool

    init(original: Playlist?, title: String, summary: String, songs: [Song], cover: Data? = nil, opensWhenSaved: Bool = false) {
        id = UUID()
        self.original = original
        self.title = title
        self.summary = summary
        self.songs = songs
        self.cover = cover
        self.opensWhenSaved = opensWhenSaved
    }

    static func new(with tracks: [Track] = [], opensWhenSaved: Bool = false) -> PlaylistDraft {
        PlaylistDraft(original: nil, title: "", summary: "", songs: tracks.map { Song(track: $0) }, opensWhenSaved: opensWhenSaved)
    }

    /// The editor loads the songs (with their slots) when it opens.
    static func editing(_ playlist: Playlist) -> PlaylistDraft {
        PlaylistDraft(original: playlist, title: playlist.title, summary: playlist.blurb ?? "", songs: [])
    }

    var isNew: Bool { original == nil }
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { !trimmedTitle.isEmpty && (!isNew || !songs.isEmpty) }

    /// The description as typed. A seasonal mix's `truffle-mix:` tag rides along unseen, so a new blurb
    /// doesn't unhook the mix from Home.
    var summaryToSave: String {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tag = original?.summary?.split(separator: " ").last(where: { $0.hasPrefix("truffle-mix:") }) else { return text }
        return text.isEmpty ? String(tag) : "\(text) \(tag)"
    }
}

/// The fewest `move` calls that turn a playlist's order into another: the longest run already in
/// order stays put, and every other slot moves right after the one it should follow (or to the top).
enum PlaylistReorder {
    struct Move: Equatable, Sendable {
        let itemID: Int
        /// nil: to the top.
        let after: Int?
    }

    static func moves(from current: [Int], to desired: [Int]) -> [Move] {
        let present = Set(current)
        let target = desired.filter(present.contains)
        let wanted = Set(target)
        var positions: [Int: Int] = [:]
        for (position, itemID) in current.filter(wanted.contains).enumerated() where positions[itemID] == nil {
            positions[itemID] = position
        }
        let staying = Set(longestIncreasing(target.map { positions[$0] ?? 0 }).map { target[$0] })
        return target.enumerated().compactMap { index, itemID in
            staying.contains(itemID) ? nil : Move(itemID: itemID, after: index == 0 ? nil : target[index - 1])
        }
    }

    /// What Plex does with a move, on a plain list (for checking a plan).
    static func apply(_ move: Move, to order: inout [Int]) {
        guard let from = order.firstIndex(of: move.itemID) else { return }
        order.remove(at: from)
        let to = move.after.flatMap { order.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        order.insert(move.itemID, at: to)
    }

    /// Indices of one longest strictly increasing run (patience sorting, n log n).
    static func longestIncreasing(_ values: [Int]) -> [Int] {
        var tails: [Int] = []
        var previous = Array(repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run: [Int] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(cursor)
            cursor = previous[cursor]
        }
        return run.reversed()
    }
}

struct PlaylistSaveResult: Sendable {
    let playlist: Playlist
    /// What didn't stick after a new playlist was made ("cover", "description"); the playlist itself did.
    let missed: [String]
}

extension MusicLibrary {
    /// New: create it with the songs in order, then the description and the cover. Yours: rename,
    /// description, cover, then the songs. Either way the playlists refresh and the saved one comes back.
    func save(_ draft: PlaylistDraft, replacing before: [PlaylistDraft.Song] = []) async throws -> PlaylistSaveResult {
        let sw = Stopwatch()
        let title = draft.trimmedTitle
        guard !title.isEmpty else { throw PlaylistEditError.needsName }
        let summary = draft.summaryToSave
        var missed: [String] = []
        let id: String
        var fallback: Playlist
        if let original = draft.original {
            id = original.id
            fallback = original
            Logger.library.info("[playlist] saving \(id, privacy: .public): \(before.count) → \(draft.songs.count) song(s), cover=\(draft.cover != nil)")
            if title != original.title {
                try await renamePlaylist(id, to: title)
                fallback.title = title
            }
            if summary != (original.summary ?? "") { try await setPlaylistSummary(id, summary) }
            if let cover = draft.cover { try await uploadPlaylistCover(id, jpeg: cover) }
            try await syncSongs(of: id, from: before, to: draft.songs)
        } else {
            Logger.library.info("[playlist] making \(title, privacy: .public): \(draft.songs.count) song(s), description=\(!summary.isEmpty), cover=\(draft.cover != nil)")
            let made = try await createPlaylist(named: title, with: draft.songs.map(\.track))
            id = made.id
            fallback = made
            // It exists now: a description or cover that doesn't stick shouldn't lose it.
            if !summary.isEmpty {
                do {
                    try await setPlaylistSummary(id, summary)
                } catch {
                    missed.append("description")
                    Logger.library.error("[playlist] summary for \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if let cover = draft.cover {
                do {
                    try await uploadPlaylistCover(id, jpeg: cover)
                } catch {
                    missed.append("cover")
                    Logger.library.error("[playlist] cover for \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        notePlaylistChanged(id)
        await refreshPlaylists()
        let saved = playlists.first { $0.id == id } ?? fallback
        Logger.library.info("[playlist] saved \(id, privacy: .public) (\(saved.trackCount) songs, thumb=\(saved.thumb != nil)) in \(sw.ms, format: .fixed(precision: 0))ms; missed \(missed.joined(separator: ","), privacy: .public)")
        return PlaylistSaveResult(playlist: saved, missed: missed)
    }

    /// Makes a playlist's songs match the editor's list: removals, then additions (Plex appends them),
    /// then the fewest moves into the editor's order.
    private func syncSongs(of playlistID: String, from before: [PlaylistDraft.Song], to after: [PlaylistDraft.Song]) async throws {
        let kept = Set(after.compactMap(\.itemID))
        let removals = before.compactMap(\.itemID).filter { !kept.contains($0) }
        for itemID in removals { try await removeFromPlaylist(playlistID, itemID: itemID) }
        let additions = after.filter { $0.itemID == nil }
        try await appendSongs(additions.map(\.track), to: playlistID)
        // Where Plex has them now: the kept slots in their old order, then the new ones.
        let landed = before.filter { $0.itemID.map(kept.contains) ?? false }.map(\.id) + additions.map(\.id)
        guard landed != after.map(\.id) else {
            Logger.library.info("[playlist] \(playlistID, privacy: .public): -\(removals.count) +\(additions.count), order already right")
            return
        }
        let entries = try await playlistEntries(of: playlistID)
        var fresh = entries.map(\.itemID).filter { !kept.contains($0) }.makeIterator()
        let desired = after.map { $0.itemID ?? fresh.next() ?? -1 }
        let moves = PlaylistReorder.moves(from: entries.map(\.itemID), to: desired)
        for move in moves { try await movePlaylistItem(playlistID, itemID: move.itemID, after: move.after) }
        Logger.library.info("[playlist] \(playlistID, privacy: .public): -\(removals.count) +\(additions.count), \(moves.count) move(s)")
    }
}
