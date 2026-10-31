import SwiftUI
import os

struct AlbumView: View {
    let album: Album
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var tracks: [Track] = []
    @State private var loading = true

    private var source: PlaySource { PlaySource(kind: .album, title: album.title, id: album.id, albumInOrder: true) }
    private var discs: [Int] { Array(Set(tracks.compactMap(\.discNumber))).sorted() }

    var body: some View {
        List {
            VStack(spacing: 14) {
                ArtworkView(thumb: album.thumb, pixels: 700, cornerRadius: 16)
                    .frame(width: 250, height: 250)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                VStack(spacing: 4) {
                    Text(album.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let artist = library.albumArtist(for: album) {
                        NavigationLink(value: Route.artist(artist)) {
                            Text(album.artist).font(.title3).foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(album.artist).font(.title3).foregroundStyle(.secondary)
                    }
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                PlayShuffleButtons(play: { player.play(tracks, source: source) },
                                   shuffle: { player.play(tracks, source: PlaySource(kind: .album, title: album.title, id: album.id), shuffled: true) })
                    .disabled(tracks.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            ForEach(discs.count > 1 ? discs : [discs.first ?? 0], id: \.self) { disc in
                Section(discs.count > 1 ? "Disc \(disc)" : "") {
                    ForEach(tracks.filter { discs.count < 2 || $0.discNumber == disc }) { track in
                        Button {
                            let index = tracks.firstIndex(of: track) ?? 0
                            player.play(tracks, startAt: index, source: source)
                        } label: {
                            TrackRow(track: track, number: track.trackNumber, showsArtist: track.artist != album.artist)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenu(track: track) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && tracks.isEmpty { ProgressView() } }
        .task(id: album.id) {
            loading = true
            do {
                tracks = try await library.tracks(of: album)
            } catch {
                Logger.ui.error("[ui] album \(album.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            loading = false
        }
    }

    private var details: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        if !tracks.isEmpty {
            parts.append(tracks.count.counted("song"))
            parts.append(tracks.reduce(0) { $0 + $1.duration }.shortDurationString)
        }
        return parts.joined(separator: " · ")
    }
}

struct ArtistView: View {
    let artist: Artist
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var albums: [Album] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ArtworkView(thumb: artist.thumb, pixels: 600, circle: true, placeholderSymbol: "music.mic")
                    .frame(width: 180, height: 180)
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                Text(artist.title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                PlayShuffleButtons(play: { playAll(shuffled: false) }, shuffle: { playAll(shuffled: true) })
                    .padding(.horizontal, 20)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(albums) { album in
                        NavigationLink(value: Route.album(album)) {
                            AlbumTile(album: album, width: 160)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && albums.isEmpty { ProgressView() } }
        .task(id: artist.id) {
            loading = true
            albums = (try? await library.albums(of: artist)) ?? []
            loading = false
        }
    }

    private func playAll(shuffled: Bool) {
        Task {
            do {
                let tracks = try await library.tracks(of: artist)
                player.play(tracks, source: PlaySource(kind: .artist, title: artist.title, id: artist.id), shuffled: shuffled)
            } catch {
                router.say("Couldn't load \(artist.title)")
            }
        }
    }
}

struct PlaylistView: View {
    let playlist: Playlist
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var exhausted = false

    private var source: PlaySource { PlaySource(kind: .playlist, title: playlist.title, id: playlist.id) }

    var body: some View {
        List {
            VStack(spacing: 14) {
                ArtworkView(thumb: playlist.thumb, pixels: 700, cornerRadius: 16, placeholderSymbol: "music.note.list")
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                VStack(spacing: 4) {
                    Text(playlist.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                PlayShuffleButtons(play: { player.play(tracks, source: source) },
                                   shuffle: { Task { await player.shuffle(playlist) } })
                    .disabled(tracks.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    player.play(tracks, startAt: index, source: source)
                } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
                .contextMenu { TrackMenu(track: track) }
                .onAppear {
                    if index == tracks.count - 20 { Task { await loadMore() } }
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading && tracks.isEmpty { ProgressView() } }
        .task(id: playlist.id) { await loadMore() }
    }

    private var subtitle: String {
        var parts = [playlist.trackCount.counted("song")]
        if playlist.duration > 0 { parts.append(playlist.duration.shortDurationString) }
        if playlist.isSmart { parts.append("Smart playlist") }
        return parts.joined(separator: " · ")
    }

    /// Pages of 200, so "All Music" (16,000 songs) opens at once.
    private func loadMore() async {
        guard !exhausted else { return }
        loading = true
        do {
            let page = try await library.tracks(of: playlist, start: tracks.count, size: 200)
            tracks += page
            exhausted = page.count < 200 || tracks.count >= playlist.trackCount
        } catch {
            Logger.ui.error("[ui] playlist \(playlist.title, privacy: .public) page failed: \(error.localizedDescription, privacy: .public)")
            exhausted = true
        }
        loading = false
    }
}
