import SwiftUI

enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case liked
    case artists
    case albums
    case playlists
}

/// App-wide things any screen can ask for: the Add to Playlist sheet, the player, a short message.
@MainActor @Observable
final class AppRouter {
    var addingToPlaylist: [Track]?
    var showsPlayer = false
    var toast: String?

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
