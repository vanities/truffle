import AppIntents

/// Phrases Siri knows without any setup, also in Spotlight, the Shortcuts app and the Action button.
/// Mix and playlist names come from the entities' suggestions, refreshed by `SiriSetup`.
struct TruffleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShuffleAllIntent(), phrases: [
            "Shuffle all in \(.applicationName)",
            "Shuffle everything in \(.applicationName)",
            "Shuffle my music in \(.applicationName)",
            "Play everything in \(.applicationName)",
        ], shortTitle: "Shuffle All", systemImageName: "shuffle")
        AppShortcut(intent: PlayLikedIntent(), phrases: [
            "Play my liked songs in \(.applicationName)",
            "Play the good stuff in \(.applicationName)",
            "Play my hearts in \(.applicationName)",
        ], shortTitle: "Liked", systemImageName: "heart.fill")
        AppShortcut(intent: PlayMixIntent(), phrases: [
            "Play \(\.$mix) in \(.applicationName)",
            "Play the \(\.$mix) in \(.applicationName)",
            "Play a mix in \(.applicationName)",
        ], shortTitle: "Play a Mix", systemImageName: "sparkles")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "Play my \(\.$playlist) playlist in \(.applicationName)",
            "Play the \(\.$playlist) playlist in \(.applicationName)",
            "Play a playlist in \(.applicationName)",
        ], shortTitle: "Play a Playlist", systemImageName: "music.note.list")
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
