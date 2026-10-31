import AppIntents
import Foundation

/// A playlist from the server, from the top or shuffled.
struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Playlist"
    static let description: IntentDescription? = IntentDescription("One of your Plex playlists, from the top or shuffled.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffled
        }
    }

    func perform() async throws -> some IntentResult {
        try await IntentPlayback.shared.playPlaylist(id: playlist.id, shuffled: shuffled)
        return .result()
    }
}

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistQuery()

    let id: String
    let title: String
    let songs: Int

    init(_ playlist: Playlist) {
        id = playlist.id
        title = playlist.title
        songs = playlist.trackCount
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(songs.counted("song"))", image: .init(systemName: "music.note.list"))
    }
}

/// The server's playlists, as the library last loaded them (the saved list on a cold start).
struct PlaylistQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [PlaylistEntity.ID]) async throws -> [PlaylistEntity] {
        let playlists = try await IntentPlayback.shared.playlists()
        return identifiers.compactMap { id in playlists.first { $0.id == id }.map(PlaylistEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        try await IntentPlayback.shared.playlists()
            .map { (playlist: $0, score: MediaText.score($0.title, asked: string)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map { PlaylistEntity($0.playlist) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await IntentPlayback.shared.playlists().map(PlaylistEntity.init)
    }
}

extension IntentPlayback {
    func playlists() async throws -> [Playlist] {
        try await ready()
        return AppEnvironment.shared.library.playlists
    }

    func playPlaylist(id: String, shuffled: Bool) async throws {
        guard let playlist = try await playlists().first(where: { $0.id == id }) else { throw IntentFailure.notFound }
        try await play(.forPlaylist(playlist, shuffled: shuffled), from: "playlist")
    }
}
