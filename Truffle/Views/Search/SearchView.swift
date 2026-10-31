import SwiftUI
import os

struct SearchView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @State private var text = ""
    @State private var results = SearchResults()
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(results.artists) { artist in
                            NavigationLink(value: Route.artist(artist)) { ArtistRow(artist: artist) }
                        }
                    }
                }
                if !results.albums.isEmpty {
                    Section("Albums") {
                        ForEach(results.albums) { album in
                            NavigationLink(value: Route.album(album)) {
                                HStack(spacing: 12) {
                                    ArtworkView(thumb: album.thumb, pixels: 120, cornerRadius: 6)
                                        .frame(width: 46, height: 46)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title).lineLimit(1)
                                        Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                if !results.tracks.isEmpty {
                    Section("Songs") {
                        ForEach(Array(results.tracks.enumerated()), id: \.element.id) { index, track in
                            Button {
                                player.play(results.tracks, startAt: index, source: PlaySource(kind: .search, title: "Search"))
                            } label: {
                                TrackRow(track: track)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenu(track: track) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .searchable(text: $text, prompt: "Artists, albums, songs")
            .overlay {
                if searching && results.isEmpty {
                    ProgressView()
                } else if text.count >= 2 && results.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else if text.isEmpty {
                    ContentUnavailableView("What are we listening to?", systemImage: "magnifyingglass")
                }
            }
            .task(id: text) {
                // Type-ahead: wait for a pause in typing before asking the server.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                searching = true
                do {
                    let found = try await library.search(text)
                    if !Task.isCancelled { results = found }
                } catch {
                    Logger.ui.info("[search] failed: \(error.localizedDescription, privacy: .public)")
                }
                searching = false
            }
            .libraryDestinations()
        }
    }
}
