import AppIntents
import Intents
import UIKit
import os

/// Siri hands "Play … on Truffle" to the app (iOS asks the app delegate, and only does so for apps with
/// multiple scenes, which CarPlay already makes Truffle).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        guard intent is INPlayMediaIntent else {
            Logger.siri.info("[siri] no handler for \(String(describing: type(of: intent)), privacy: .public)")
            return nil
        }
        return PlayMediaIntentHandler()
    }
}

/// Keeps Siri current with the library: playlist names it should hear right (they're often made-up
/// words), the App Shortcuts' playlist and mix names, and asks once for Siri permission.
@MainActor
final class SiriSetup {
    private let library: MusicLibrary
    private var lastTitles: [String] = []
    private var asked = false

    init(library: MusicLibrary) {
        self.library = library
    }

    func start() {
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = library.playlists
            _ = library.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        let titles = library.playlists.map(\.title)
        if titles != lastTitles {
            lastTitles = titles
            let sw = Stopwatch()
            INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: titles), of: .mediaPlaylistTitle)
            TruffleShortcuts.updateAppShortcutParameters()
            Logger.siri.info("[siri] vocabulary: \(titles.count) playlist name(s) in \(sw.ms, format: .fixed(precision: 1))ms")
        }
        askIfNeeded()
    }

    /// Once the library's ready in the foreground, so the prompt comes while someone's using the app.
    /// Not in the demo: store screenshots and App Review start there.
    private func askIfNeeded() {
        guard !asked, library.phase == .ready, !library.isDemo,
              UIApplication.shared.applicationState == .active,
              INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
        asked = true
        Logger.siri.info("[siri] asking for permission")
        INPreferences.requestSiriAuthorization { status in
            Logger.siri.info("[siri] permission: \(status.rawValue)")
        }
    }
}
