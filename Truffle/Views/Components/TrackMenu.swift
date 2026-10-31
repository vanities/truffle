import SwiftUI
import os

/// The long-press menu on a song.
struct TrackMenu: View {
    let track: Track
    @Environment(PlayerEngine.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.playNext([track])
            router.say("Playing next")
        }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
            player.addToQueue([track])
            router.say("Queued")
        }
        let liked = library.isLiked(track)
        Button(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart") {
            Task {
                do {
                    try await library.setLiked(track, !liked)
                } catch {
                    router.say("The heart didn't stick")
                }
            }
        }
        Button("Add to Playlist…", systemImage: "music.note.list") {
            router.addingToPlaylist = [track]
        }
    }
}

/// Pick one of your playlists (smart ones can't be added to), or make a new one in the editor.
struct AddToPlaylistSheet: View {
    let tracks: [Track]
    @Environment(MusicLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private var editable: [Playlist] { library.playlists.filter { !$0.isSmart } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        router.startNewPlaylist(with: tracks)
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
                Section(editable.isEmpty ? "" : "Your playlists") {
                    ForEach(editable) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(working)
            .navigationTitle(tracks.count == 1 ? "Add \"\(tracks[0].title)\"" : "Add \(tracks.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func add(to playlist: Playlist) {
        working = true
        Task {
            do {
                try await library.add(tracks, to: playlist)
                router.say("Added to \(playlist.title)")
                dismiss()
            } catch {
                working = false
                router.say("Couldn't add to \(playlist.title)")
                Logger.ui.error("[ui] add to playlist failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
