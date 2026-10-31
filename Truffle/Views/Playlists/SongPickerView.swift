import SwiftUI
import os

/// Add Songs: search the library and tap songs to pick them (tap again to unpick). With nothing
/// typed, it shows what's picked so far.
struct SongPickerView: View {
    @Binding var songs: [PlaylistDraft.Song]
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.onTintColor) private var onTint
    @State private var text: String
    @State private var results: [Track] = []
    @State private var searching = false

    init(songs: Binding<[PlaylistDraft.Song]>, initialQuery: String = "") {
        _songs = songs
        _text = State(initialValue: initialQuery)
    }

    private var pickedIDs: Set<String> { Set(songs.map(\.track.id)) }

    /// Each picked song once, in the order picked.
    private var pickedTracks: [Track] {
        var seen = Set<String>()
        return songs.map(\.track).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        List {
            if text.isEmpty {
                if !songs.isEmpty {
                    Section("Picked") {
                        ForEach(pickedTracks) { row($0) }
                    }
                }
            } else {
                ForEach(results) { row($0) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Add Songs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your songs")
        .overlay {
            if searching && results.isEmpty {
                ProgressView()
            } else if text.count >= 2 && results.isEmpty {
                ContentUnavailableView.search(text: text)
            } else if text.isEmpty && songs.isEmpty {
                ContentUnavailableView("What's going on it?", systemImage: "magnifyingglass")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !songs.isEmpty {
                Button { dismiss() } label: {
                    Label("\(songs.count) picked", systemImage: "checkmark")
                        .font(.headline)
                        .foregroundStyle(onTint)
                        .frame(minHeight: 34)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.bottom, 8)
                .contentTransition(.numericText())
                .animation(.snappy, value: songs.count)
            }
        }
        .task(id: text) { await search() }
    }

    private func row(_ track: Track) -> some View {
        let picked = pickedIDs.contains(track.id)
        return Button {
            toggle(track)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(thumb: track.thumb, pixels: 120, cornerRadius: 6)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1, atAccessibilitySizes: nil)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1, atAccessibilitySizes: nil)
                }
                Spacer(minLength: 8)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func toggle(_ track: Track) {
        if let index = songs.lastIndex(where: { $0.track.id == track.id }) {
            songs.remove(at: index)
            Logger.ui.debug("[picker] unpicked \(track.id, privacy: .public), \(songs.count) picked")
        } else {
            songs.append(PlaylistDraft.Song(track: track))
            Logger.ui.debug("[picker] picked \(track.id, privacy: .public), \(songs.count) picked")
        }
    }

    private func search() async {
        guard !text.isEmpty else {
            results = []
            return
        }
        // Type-ahead: wait for a pause in typing before asking the server.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searching = true
        do {
            let found = try await library.search(text, limit: 40)
            if !Task.isCancelled { results = found.tracks }
        } catch {
            Logger.ui.info("[picker] search failed: \(error.localizedDescription, privacy: .public)")
        }
        searching = false
    }
}
