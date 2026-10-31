import SwiftUI
import os

struct LibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.libraryPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 0) {
                        CategoryLink(route: .playlists, title: "Playlists", symbol: "music.note.list", count: library.playlists.count)
                        Divider().padding(.leading, 58)
                        CategoryLink(route: .artists, title: "Artists", symbol: "music.mic", count: library.artists.count)
                        Divider().padding(.leading, 58)
                        CategoryLink(route: .albums, title: "Albums", symbol: "square.stack", count: library.albums.count)
                        Divider().padding(.leading, 58)
                        CategoryLink(route: .liked, title: "Liked Songs", symbol: "heart", count: library.likedCount)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    .padding(.horizontal, 16)

                    if !library.recentlyAdded.isEmpty {
                        Text("Recently Added")
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 20)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                            ForEach(library.recentlyAdded) { album in
                                NavigationLink(value: Route.album(album)) {
                                    AlbumTile(album: album, width: 160)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Library")
            .refreshable { await library.refresh() }
            .libraryDestinations()
        }
    }
}

private struct CategoryLink: View {
    let route: Route
    let title: String
    let symbol: String
    let count: Int

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                Text(title)
                    .font(.title3)
                    .foregroundStyle(.primary)
                Spacer()
                if count > 0 {
                    Text(count.grouped)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ArtistsView: View {
    @Environment(MusicLibrary.self) private var library
    @AppStorage(ArtistSort.defaultsKey) private var sort: ArtistSort = .standard
    @State private var filter = ""

    /// Every artist is already loaded, so the sort happens here.
    private var artists: [Artist] {
        sort.sorted(filter.isEmpty ? library.artists : library.artists.filter { $0.title.localizedStandardContains(filter) })
    }

    var body: some View {
        List(artists) { artist in
            NavigationLink(value: Route.artist(artist)) {
                ArtistRow(artist: artist)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .searchable(text: $filter, prompt: "Find an artist")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SortMenu(selection: $sort) }
        }
    }
}

struct AlbumsView: View {
    @Environment(MusicLibrary.self) private var library
    @AppStorage(AlbumSort.defaultsKey) private var sort: AlbumSort = .standard
    @State private var filter = ""

    /// Every album is already loaded, so the sort happens here.
    private var albums: [Album] {
        sort.sorted(filter.isEmpty ? library.albums
            : library.albums.filter { $0.title.localizedStandardContains(filter) || $0.artist.localizedStandardContains(filter) })
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink(value: Route.album(album)) {
                        AlbumTile(album: album, width: 160)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("Albums")
        .searchable(text: $filter, prompt: "Find an album")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SortMenu(selection: $sort) }
        }
    }
}

struct PlaylistsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @AppStorage(PlaylistSort.defaultsKey) private var sort: PlaylistSort = .standard

    var body: some View {
        List(sort.sorted(library.playlists)) { playlist in
            NavigationLink(value: Route.playlist(playlist)) {
                PlaylistRow(playlist: playlist)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SortMenu(selection: $sort) }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Playlist", systemImage: "plus") {
                    router.editingPlaylist = .new(opensWhenSaved: true)
                }
            }
        }
        .overlay {
            if library.playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                                       description: Text("Tap + and make one."))
            }
        }
        .refreshable { await library.refreshPlaylists() }
    }
}

struct LikedView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @AppStorage(LikedSort.defaultsKey) private var sort: LikedSort = .standard
    @State private var tracks: [Track] = []
    @State private var loading = true

    private var source: PlaySource { PlaySource(kind: .liked, title: "Liked Songs") }

    var body: some View {
        List {
            if !tracks.isEmpty {
                PlayShuffleButtons(play: { player.play(tracks, source: source) },
                                   shuffle: { player.play(tracks, source: source, shuffled: true) })
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    player.play(tracks, startAt: index, source: source)
                } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
                .contextMenu { TrackMenu(track: track) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Liked Songs")
        .overlay {
            if loading && tracks.isEmpty {
                ProgressView()
            } else if tracks.isEmpty {
                ContentUnavailableView("No Likes Yet", systemImage: "heart", description: Text("Tap the heart. Go on."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SortMenu(selection: $sort) }
        }
        .task(id: sort) { await load() }
        .refreshable { await load() }
    }

    /// Liked songs come a page at a time from Plex, so Plex does the sorting.
    private func load() async {
        loading = true
        do {
            tracks = try await library.likedTracks(sort: sort)
        } catch {
            // A newer sort replaced this load; it brings its own songs.
            guard !Task.isCancelled else { return }
            Logger.ui.error("[liked] load by \(sort.plexSort, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if !tracks.isEmpty { router.say("Couldn't sort that way") }
        }
        loading = false
    }
}
