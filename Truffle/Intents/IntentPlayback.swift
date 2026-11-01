import AppIntents
import Foundation
import UIKit
import os

/// What Siri, Shortcuts or the widget asked to hear, as the calls Home and the car make.
enum PlaybackPlan: Equatable, Sendable {
    case mix(Mix, theme: SeasonTheme)
    case shufflePlaylist(Playlist)
    case playlist(Playlist)
    /// From the top, or from one of its songs (a song asked for by name plays on into its album).
    case album(Album, startAt: String?, shuffled: Bool)
    case artist(Artist)
    /// A song with no album to play on into.
    case song(Track)

    /// A playlist plays from the top unless asked to shuffle. One too big to download shuffles anyway,
    /// by position, the way the car's Shuffle row does.
    static func forPlaylist(_ playlist: Playlist, shuffled: Bool) -> PlaybackPlan {
        shuffled || playlist.isLarge ? .shufflePlaylist(playlist) : .playlist(playlist)
    }

    static func forSong(_ track: Track) -> PlaybackPlan {
        guard let albumID = track.albumID else { return .song(track) }
        return .album(Album(id: albumID, title: track.album, artist: track.artist, artistID: track.artistID), startAt: track.id, shuffled: false)
    }

    var title: String {
        switch self {
        case .mix(let mix, _): mix.title
        case .shufflePlaylist(let playlist), .playlist(let playlist): playlist.title
        case .album(let album, _, _): album.title
        case .artist(let artist): artist.title
        case .song(let track): track.title
        }
    }
}

/// Why an intent couldn't play, in words Siri can say.
enum IntentFailure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case signedOut
    case unreachable
    case notFound
    case didNotStart(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Plex in Truffle first."
        case .unreachable: "Your Plex server isn't answering."
        case .notFound: "Truffle couldn't find that one."
        case .didNotStart(let message): "\(message)"
        }
    }
}

/// The app's side of the intents the widget also carries (its copy only logs).
enum IntentRunner {
    @MainActor static func playMix(id: String) async throws {
        try await IntentPlayback.shared.playMix(id: id)
    }

    @MainActor static func resume() async throws {
        try await IntentPlayback.shared.resume()
    }
}

/// Starts what an intent asked for through the same PlayerEngine calls Home and the car use.
@MainActor
final class IntentPlayback {
    static let shared = IntentPlayback(environment: .shared)

    private let environment: AppEnvironment
    private var library: MusicLibrary { environment.library }
    private var player: PlayerEngine { environment.player }

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func playMix(id: String) async throws {
        guard let entry = MixCatalog.entry(id: id, at: SeasonCalendar.now, southern: environment.settings.isSouthern) else {
            Logger.intents.error("[intent] no mix \(id, privacy: .public)")
            throw IntentFailure.notFound
        }
        try await play(.mix(entry.mix, theme: entry.theme), from: "mix \(id)")
    }

    /// The queue picks up where it was (from the phone if it's saved there, so no wait on the server), or
    /// Shuffle All when there's nothing to pick up. Same rule as Play in the Car (`CarAutoplay`).
    func resume() async throws {
        let state = UIApplication.shared.applicationState.carLogName
        guard library.isSignedIn else {
            CarLog.shared.note("Resume shortcut (app \(state)): signed out")
            throw IntentFailure.signedOut
        }
        if player.isPlaying || player.isLoading {
            CarLog.shared.note("Resume shortcut (app \(state)): already playing")
            return
        }
        let resumes = CarAutoplay.canResume(player.queue, at: player.currentTime, endless: player.isEndless)
        CarLog.shared.note("Resume shortcut (app \(state)): \(resumes ? "picking up the queue" : "Shuffle All")")
        CarLog.shared.expectSound(after: "the Resume shortcut") { [player] in player.startState }
        CarPlayInterface.current?.showNowPlaying()
        if resumes {
            player.play()
        } else {
            try await play(.mix(.shuffleAll, theme: SeasonCalendar.theme(for: SeasonCalendar.now, southern: environment.settings.isSouthern)),
                           from: "resume")
        }
    }

    func play(_ plan: PlaybackPlan, from origin: String) async throws {
        let sw = Stopwatch()
        Logger.intents.info("[intent] \(origin, privacy: .public) → \(plan.title, privacy: .public)")
        try await ready()
        CarPlayInterface.current?.showNowPlaying()
        switch plan {
        case .mix(let mix, let theme):
            await player.play(mix, theme: theme)
        case .shufflePlaylist(let playlist):
            await player.shuffle(playlist)
        case .playlist(let playlist):
            let tracks = try await library.allTracks(of: playlist)
            try start(tracks, source: PlaySource(kind: .playlist, title: playlist.title, id: playlist.id))
        case .album(let album, let songID, let shuffled):
            let tracks = try await library.tracks(of: album)
            let index = songID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
            try start(tracks, at: index, source: PlaySource(kind: .album, title: album.title, id: album.id, albumInOrder: !shuffled), shuffled: shuffled)
        case .artist(let artist):
            let tracks = try await library.tracks(of: artist)
            try start(tracks, source: PlaySource(kind: .artist, title: artist.title, id: artist.id), shuffled: true)
        case .song(let track):
            try start([track], source: PlaySource(kind: .songs, title: track.title, id: track.id))
        }
        if let message = player.errorMessage, !player.isPlaying, !player.isLoading {
            Logger.intents.error("[intent] \(plan.title, privacy: .public) didn't start: \(message, privacy: .public)")
            throw IntentFailure.didNotStart(message)
        }
        Logger.intents.info("[intent] \(plan.title, privacy: .public) started in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    private func start(_ tracks: [Track], at index: Int = 0, source: PlaySource, shuffled: Bool = false) throws {
        guard !tracks.isEmpty else { throw IntentFailure.notFound }
        player.play(tracks, startAt: index, source: source, shuffled: shuffled)
    }

    /// An intent can wake the app cold. The saved lists are back at once and requests reconnect on their
    /// own (`withClient`), so only a library with nothing saved yet waits for the server.
    func ready(timeout: Duration = .seconds(12)) async throws {
        guard library.isSignedIn else { throw IntentFailure.signedOut }
        if library.phase == .ready || library.trackCount > 0 { return }
        let sw = Stopwatch()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch library.phase {
            case .ready:
                Logger.intents.info("[intent] library ready after \(sw.ms, format: .fixed(precision: 0))ms")
                return
            case .signedOut: throw IntentFailure.signedOut
            case .unreachable, .failed: throw IntentFailure.unreachable
            case .connecting: try await Task.sleep(for: .milliseconds(100))
            }
        }
        Logger.intents.error("[intent] library not ready after \(sw.ms, format: .fixed(precision: 0))ms")
        throw IntentFailure.unreachable
    }
}
