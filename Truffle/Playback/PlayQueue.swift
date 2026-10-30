import Foundation

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// The queue's bookkeeping, kept apart from AVPlayer so the rules are testable.
struct PlayQueue: Codable, Sendable, Equatable {
    private(set) var tracks: [Track] = []
    private(set) var index = 0
    var repeatMode: RepeatMode = .off

    var current: Track? { tracks[safe: index] }
    var isEmpty: Bool { tracks.isEmpty }
    var upcoming: ArraySlice<Track> { index + 1 < tracks.count ? tracks[(index + 1)...] : [] }
    var played: ArraySlice<Track> { tracks.prefix(index) }

    mutating func replace(with tracks: [Track], startAt start: Int = 0) {
        self.tracks = tracks
        index = tracks.isEmpty ? 0 : min(max(0, start), tracks.count - 1)
    }

    /// Where playback goes when the current song ends on its own. Repeat One replays it.
    func indexAfterEnd() -> Int? {
        if repeatMode == .one, current != nil { return index }
        return indexForNext()
    }

    /// Where Next goes. Repeat One doesn't trap the Next button on one song.
    func indexForNext() -> Int? {
        if index + 1 < tracks.count { return index + 1 }
        return repeatMode == .off || tracks.isEmpty ? nil : 0
    }

    /// Where Previous goes when it isn't restarting the song: nil at the start without repeat.
    func indexForPrevious() -> Int? {
        if index > 0 { return index - 1 }
        return repeatMode == .all && !tracks.isEmpty ? tracks.count - 1 : nil
    }

    mutating func move(to newIndex: Int) {
        guard tracks.indices.contains(newIndex) else { return }
        index = newIndex
    }

    mutating func insertNext(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        if tracks.isEmpty {
            replace(with: newTracks)
        } else {
            tracks.insert(contentsOf: newTracks, at: index + 1)
        }
    }

    mutating func append(_ newTracks: [Track]) {
        if tracks.isEmpty {
            replace(with: newTracks)
        } else {
            tracks.append(contentsOf: newTracks)
        }
    }

    /// `offsets` count from the first upcoming song.
    mutating func removeUpcoming(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 }.filter { tracks.indices.contains($0) })
        tracks.remove(atOffsets: absolute)
    }

    mutating func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        guard index + 1 <= tracks.count else { return }
        var upcoming = Array(tracks[(index + 1)...])
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        tracks.replaceSubrange((index + 1)..., with: upcoming)
    }

    /// Swaps in a fresher copy of a song everywhere it appears (details loaded, rating changed).
    mutating func update(_ track: Track) {
        for position in tracks.indices where tracks[position].id == track.id {
            tracks[position] = track
        }
    }

    /// An endless shuffle only ever grows; past this many played songs the oldest go.
    mutating func trimPlayed(keeping count: Int) {
        let excess = index - count
        guard excess > 0 else { return }
        tracks.removeFirst(excess)
        index -= excess
    }
}
