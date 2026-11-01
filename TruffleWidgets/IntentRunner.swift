import os

/// The widget's buttons name the intents, but AudioPlaybackIntents run in the app's process, so this
/// copy should never be reached. If it is, the log says so.
enum IntentRunner {
    static func playMix(id: String) async throws {
        Logger.widget.error("[widget] \(id, privacy: .public) ran in the widget extension, not the app")
    }

    static func resume() async throws {
        Logger.widget.error("[widget] resume ran in the widget extension, not the app")
    }
}
