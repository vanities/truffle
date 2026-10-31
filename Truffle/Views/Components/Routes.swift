import SwiftUI
import os

enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case liked
    case artists
    case albums
    case playlists
}

/// App-wide things any screen can ask for: the Add to Playlist sheet, the playlist editor, the player,
/// a short message.
@MainActor @Observable
final class AppRouter {
    var addingToPlaylist: [Track]?
    /// The playlist editor. Set while Add to Playlist is up, it takes that sheet's place.
    var editingPlaylist: PlaylistDraft?
    var showsPlayer = false
    var toast: String?
    var libraryPath: [Route] = []
    /// Asks a screen to scroll to a marked spot (store screenshots).
    var scrollTarget: String?

    /// The one sheet up: the editor wins over Add to Playlist. A change of sheet makes SwiftUI swap them.
    var sheet: AppSheet? {
        if let editingPlaylist { return .editPlaylist(editingPlaylist) }
        return addingToPlaylist.map(AppSheet.addToPlaylist)
    }

    func dismissSheet() {
        editingPlaylist = nil
        addingToPlaylist = nil
    }

    /// Add to Playlist's "New Playlist…": the editor, already holding the songs.
    func startNewPlaylist(with tracks: [Track]) {
        Logger.ui.info("[router] new playlist with \(tracks.count) song(s)")
        editingPlaylist = .new(with: tracks)
        addingToPlaylist = nil
    }

    /// Shows a playlist on the Library tab's stack (after the editor made it).
    func open(_ playlist: Playlist) {
        libraryPath.append(.playlist(playlist))
    }

    func say(_ message: String) {
        toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.toast == message { self?.toast = nil }
        }
    }
}

extension View {
    /// The screens every tab can push. Applied to the stack's root, never inside a lazy container
    /// (destinations there are silently ignored).
    func libraryDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let album): AlbumView(album: album)
            case .artist(let artist): ArtistView(artist: artist)
            case .playlist(let playlist): PlaylistView(playlist: playlist)
            case .liked: LikedView()
            case .artists: ArtistsView()
            case .albums: AlbumsView()
            case .playlists: PlaylistsView()
            }
        }
    }
}

enum AppSheet: Identifiable {
    case addToPlaylist([Track])
    case editPlaylist(PlaylistDraft)

    var id: String {
        switch self {
        case .addToPlaylist(let tracks): "add:" + tracks.map(\.id).joined(separator: ",")
        case .editPlaylist(let draft): "edit:" + draft.id.uuidString
        }
    }
}
