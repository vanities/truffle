import Foundation
import os

/// Composition root shared by the phone UI and the CarPlay scene.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let library: MusicLibrary
    let player: PlayerEngine
    let nowPlaying: NowPlayingController

    private init() {
        let sw = Stopwatch()
        AudioSessionManager.configure()
        settings = AppSettings()
        library = MusicLibrary(identity: .current(), settings: settings)
        player = PlayerEngine(library: library, settings: settings)
        nowPlaying = NowPlayingController(player: player, library: library)
        nowPlaying.activate()
        #if DEBUG
        let arguments = UserDefaults.standard
        if let url = arguments.string(forKey: "TruffleServerURL").flatMap(URL.init(string:)) {
            library.startWithDirectServer(url: url, token: arguments.string(forKey: "TruffleServerToken") ?? "demo")
        } else {
            library.start()
        }
        #else
        library.start()
        #endif
        Logger.ui.info("[app] environment ready in \(sw.ms, format: .fixed(precision: 1))ms")
    }

    /// The seasonal look and mixes for right now.
    var theme: SeasonTheme { SeasonCalendar.theme(for: .now, southern: settings.isSouthern) }
}
