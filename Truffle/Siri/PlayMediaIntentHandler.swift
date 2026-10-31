import Intents
import os

/// Siri's "Play … on Truffle", handled inside the app rather than an Intents extension, so it starts the
/// music the way the app does, in the car too.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let request = MediaRequest(intent.mediaSearch, shuffled: intent.playShuffled)
        switch await SiriPlayback.shared.resolve(request) {
        case .found(let pick):
            let item = INMediaItem(identifier: pick.identifier, title: pick.title, type: pick.type, artwork: nil, artist: pick.artist)
            return [.success(with: item)]
        case .signedOut: return [.unsupported(forReason: .loginRequired)]
        case .unsupportedType: return [.unsupported(forReason: .unsupportedMediaType)]
        case .unreachable: return [.unsupported(forReason: .serviceUnavailable)]
        case .notFound: return [.unsupported()]
        }
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let request = MediaRequest(intent.mediaSearch, shuffled: intent.playShuffled)
        let code = await SiriPlayback.shared.play(identifier: intent.mediaItems?.first?.identifier, request: request)
        return INPlayMediaIntentResponse(code: code, userActivity: nil)
    }
}

/// What Siri settled on, as plain values (SiriKit's types can't cross to the main actor).
struct SiriPick: Equatable, Sendable {
    let identifier: String
    let title: String
    let artist: String?
    let type: INMediaItemType

    init(_ plan: PlaybackPlan) {
        title = plan.title
        switch plan {
        case .mix(let mix, let theme):
            (identifier, artist, type) = ("truffle:mix:\(mix.id):\(theme.id)", nil, .playlist)
        case .shufflePlaylist(let playlist), .playlist(let playlist):
            (identifier, artist, type) = ("truffle:playlist:\(playlist.id)", nil, .playlist)
        case .album(let album, let songID, _):
            (identifier, artist, type) = ("truffle:album:\(album.id):\(songID ?? "")", album.artist, songID == nil ? .album : .song)
        case .artist(let performer):
            (identifier, artist, type) = ("truffle:artist:\(performer.id)", nil, .artist)
        case .song(let track):
            (identifier, artist, type) = ("truffle:song:\(track.id)", track.artist, .song)
        }
    }
}

enum SiriOutcome: Equatable, Sendable {
    case found(SiriPick)
    case signedOut
    case unsupportedType
    case unreachable
    case notFound
}

/// Resolves a request against the library, remembers the pick for the `handle` that follows, then plays
/// it through `IntentPlayback`.
@MainActor
final class SiriPlayback {
    static let shared = SiriPlayback()

    private var picked: [String: PlaybackPlan] = [:]

    func resolve(_ request: MediaRequest) async -> SiriOutcome {
        let sw = Stopwatch()
        let asked = Self.describe(request)
        guard request.kind != .unsupported else {
            Logger.siri.info("[siri] \(asked, privacy: .public): not music")
            return .unsupportedType
        }
        do {
            try await IntentPlayback.shared.ready()
        } catch IntentFailure.signedOut {
            Logger.siri.info("[siri] \(asked, privacy: .public): signed out")
            return .signedOut
        } catch {
            Logger.siri.error("[siri] \(asked, privacy: .public): server not ready (\(sw.ms, format: .fixed(precision: 0))ms)")
            return .unreachable
        }
        let environment = AppEnvironment.shared
        let mixes = MixCatalog.all(at: SeasonCalendar.now, southern: environment.settings.isSouthern)
        guard let plan = await MediaSearchResolver.resolve(request, in: environment.library, mixes: mixes) else {
            Logger.siri.info("[siri] \(asked, privacy: .public): nothing matched in \(sw.ms, format: .fixed(precision: 0))ms")
            return .notFound
        }
        let pick = SiriPick(plan)
        picked[pick.identifier] = plan
        Logger.siri.info("[siri] \(asked, privacy: .public) → \(pick.identifier, privacy: .public) \"\(plan.title, privacy: .public)\" in \(sw.ms, format: .fixed(precision: 0))ms")
        return .found(pick)
    }

    func play(identifier: String?, request: MediaRequest) async -> INPlayMediaIntentResponseCode {
        var plan = identifier.flatMap { picked[$0] }
        if plan == nil, case .found(let pick) = await resolve(request) { plan = picked[pick.identifier] }
        guard let plan else { return .failure }
        do {
            try await IntentPlayback.shared.play(plan, from: "siri")
            return .success
        } catch IntentFailure.signedOut {
            return .failureRequiringAppLaunch
        } catch {
            Logger.siri.error("[siri] \"\(plan.title, privacy: .public)\" failed: \(String(describing: error), privacy: .public)")
            return .failure
        }
    }

    private static func describe(_ request: MediaRequest) -> String {
        var parts = ["\(request.kind)"]
        if let name = request.name { parts.append("name=\"\(name)\"") }
        if let artist = request.artist { parts.append("artist=\"\(artist)\"") }
        if let album = request.album { parts.append("album=\"\(album)\"") }
        if !request.genres.isEmpty { parts.append("genres=\(request.genres)") }
        if request.shuffled { parts.append("shuffled") }
        return parts.joined(separator: " ")
    }

    #if DEBUG
    /// `-TruffleSiri "Road Trip"` asks the handler as Siri would, and `-TruffleIntent halloween` (a
    /// `MixCatalog` id) runs the mix intent, a few seconds after launch. The simulator can't speak to Siri.
    static func runLaunchRequests() {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "TruffleSiri") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let search = INMediaSearch(mediaType: .unknown, sortOrder: .unknown, mediaName: name, artistName: nil, albumName: nil,
                                           genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil)
                let intent = INPlayMediaIntent(mediaItems: nil, mediaContainer: nil, playShuffled: nil, playbackRepeatMode: .unknown,
                                               resumePlayback: nil, playbackQueueLocation: .unknown, playbackSpeed: nil, mediaSearch: search)
                let response = await PlayMediaIntentHandler().handle(intent: intent)
                Logger.siri.info("[siri] debug ask \"\(name, privacy: .public)\" answered \(response.code.rawValue)")
            }
        }
        if let id = defaults.string(forKey: "TruffleIntent") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                do {
                    try await IntentRunner.playMix(id: id)
                } catch {
                    Logger.intents.error("[intent] debug \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
    #endif
}
