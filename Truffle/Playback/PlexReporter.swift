import Foundation
import os

/// Tells the server what's playing, the way Plex's own players do: timeline updates while a song
/// plays, and a final "stopped" when it ends. That's what shows Truffle on the server's dashboard
/// and what puts plays in the history the seasonal mixes read.
@MainActor
final class PlexReporter {
    enum State: String {
        case playing, paused, stopped
    }

    private let library: MusicLibrary
    private var lastSent: (id: String, state: State, at: Date)?

    init(library: MusicLibrary) {
        self.library = library
    }

    /// Repeats of the same state are throttled to one every 10 s; a change goes out at once.
    func report(_ state: State, track: Track, time: TimeInterval) {
        if let last = lastSent, last.id == track.id, last.state == state, Date().timeIntervalSince(last.at) < 10 { return }
        lastSent = (track.id, state, .now)
        guard let client = library.client else { return }
        let query = PlexQuery([
            ("ratingKey", track.id),
            ("key", "/library/metadata/\(track.id)"),
            ("identifier", "com.plexapp.plugins.library"),
            ("state", state.rawValue),
            ("time", String(Int(max(0, time) * 1000))),
            ("duration", String(Int(track.duration * 1000))),
        ])
        Task {
            do {
                try await client.send("GET", "/:/timeline", query)
                Logger.player.debug("[report] \(state.rawValue, privacy: .public) \(track.title, privacy: .public) at \(Int(time))s")
            } catch {
                Logger.player.info("[report] \(state.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
