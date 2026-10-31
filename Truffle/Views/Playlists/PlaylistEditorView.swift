import PhotosUI
import SwiftUI
import os

/// Make a playlist, or change one of yours: a cover from Photos, a name, a description, and songs to
/// pick, drop and drag into order. Nothing reaches Plex until Save.
struct PlaylistEditorView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlaylistDraft
    /// The playlist's songs as Plex had them, with their slots: what Save compares against.
    @State private var before: [PlaylistDraft.Song] = []
    @State private var loadingSongs = false
    @State private var saving = false
    @State private var coverItem: PhotosPickerItem?
    @State private var showsPhotos = false
    @State private var coverPreview: UIImage?
    @State private var preparingCover = false
    @State private var editMode: EditMode = .inactive
    @State private var showsPicker = false
    @State private var pickerQuery = ""

    init(draft: PlaylistDraft) {
        _draft = State(initialValue: draft)
        _coverPreview = State(initialValue: draft.cover.flatMap(UIImage.init(data:)))
    }

    var body: some View {
        NavigationStack {
            List {
                coverSection
                Section {
                    TextField("Name", text: $draft.title)
                        .font(.title3.weight(.semibold))
                        .frame(minHeight: 44)
                    TextField("Description (optional)", text: $draft.summary, axis: .vertical)
                        .lineLimit(1...4)
                        .frame(minHeight: 44)
                }
                songsSection
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(draft.isNew ? "New Playlist" : "Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsPicker) {
                SongPickerView(songs: $draft.songs, initialQuery: pickerQuery)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save", role: .confirm) { save() }
                            .disabled(!draft.canSave || preparingCover || loadingSongs)
                    }
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(hasEdits)
            .task { await loadSongs() }
            #if DEBUG
            .task {
                // `-TrufflePickerQuery light` opens Add Songs already searching (screenshots).
                guard let query = UserDefaults.standard.string(forKey: "TrufflePickerQuery") else { return }
                pickerQuery = query
                showsPicker = true
            }
            #endif
            .onChange(of: coverItem) { _, item in
                guard let item else { return }
                Task { await prepareCover(item) }
            }
        }
    }

    // MARK: - Sections

    private var coverSection: some View {
        Section {
            // The modifier form of PhotosPicker: its label closure is @Sendable and can't read view state.
            Button { showsPhotos = true } label: { coverLabel }
            .buttonStyle(.plain)
            .photosPicker(isPresented: $showsPhotos, selection: $coverItem, matching: .images)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityLabel(hasCover ? "Change cover" : "Add a cover")
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var coverLabel: some View {
        ZStack(alignment: .bottomTrailing) {
            coverArt
                .frame(width: 200, height: 200)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
                .overlay {
                    if preparingCover { ProgressView().controlSize(.large) }
                }
            Image(systemName: hasCover ? "pencil" : "photo.badge.plus")
                .font(.headline)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
                .offset(x: 10, y: 10)
        }
    }

    @ViewBuilder
    private var coverArt: some View {
        if let coverPreview {
            Image(uiImage: coverPreview)
                .resizable()
                .scaledToFill()
        } else if let thumb = draft.original?.thumb {
            ArtworkView(thumb: thumb, pixels: 600, cornerRadius: 18, placeholderSymbol: "music.note.list")
        } else {
            ZStack {
                LinearGradient(colors: [Color(.secondarySystemFill), Color(.tertiarySystemFill)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                    Text("Add a cover")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.tint)
            }
        }
    }

    private var songsSection: some View {
        Section {
            Button {
                pickerQuery = ""
                showsPicker = true
            } label: {
                Label("Add Songs", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            ForEach(draft.songs) { song in
                TrackRow(track: song.track)
            }
            .onDelete { draft.songs.remove(atOffsets: $0) }
            .onMove { draft.songs.move(fromOffsets: $0, toOffset: $1) }
            if loadingSongs {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
            }
        } header: {
            HStack {
                Text(draft.songs.isEmpty ? "Songs" : draft.songs.count.counted("song"))
                Spacer()
                if draft.songs.count > 1 {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
        } footer: {
            if draft.songs.isEmpty, !loadingSongs {
                Text("Empty for now. Go find some bangers.")
            } else if draft.songs.count > 1, !editMode.isEditing {
                Text("Swipe a song to drop it.")
            }
        }
    }

    // MARK: - State

    private var hasCover: Bool { coverPreview != nil || draft.original?.thumb != nil }

    private var hasEdits: Bool {
        draft.trimmedTitle != (draft.original?.title ?? "") || draft.summary != (draft.original?.blurb ?? "")
            || draft.cover != nil || draft.songs.map(\.id) != before.map(\.id)
    }

    // MARK: - Actions

    private func loadSongs() async {
        guard let original = draft.original, before.isEmpty else { return }
        loadingSongs = true
        let sw = Stopwatch()
        do {
            let songs = try await library.playlistEntries(of: original.id).map { PlaylistDraft.Song(track: $0.track, itemID: $0.itemID) }
            before = songs
            // Anything picked while these loaded goes after them.
            draft.songs = songs + draft.songs
            Logger.ui.info("[editor] \(original.id, privacy: .public) has \(songs.count) song(s), loaded in \(sw.ms, format: .fixed(precision: 0))ms")
        } catch {
            Logger.ui.error("[editor] songs of \(original.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            router.say("Couldn't load the songs")
        }
        loadingSongs = false
    }

    private func prepareCover(_ item: PhotosPickerItem) async {
        preparingCover = true
        let sw = Stopwatch()
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
            let jpeg = await Task.detached(priority: .userInitiated) { CoverImage.squareJPEG(from: data) }.value
            if let jpeg, let preview = UIImage(data: jpeg) {
                draft.cover = jpeg
                coverPreview = preview
                Logger.ui.info("[editor] cover \(data.count)B → \(jpeg.count)B, \(Int(preview.size.width))px in \(sw.ms, format: .fixed(precision: 0))ms")
            } else {
                Logger.ui.error("[editor] cover from \(data.count)B didn't decode")
                router.say("That photo didn't take")
            }
        } catch {
            Logger.ui.error("[editor] cover load failed: \(error.localizedDescription, privacy: .public)")
            router.say("That photo didn't take")
        }
        preparingCover = false
    }

    private func save() {
        guard draft.canSave else { return }
        saving = true
        editMode = .inactive
        let draft = draft
        let before = before
        Task {
            do {
                let result = try await library.save(draft, replacing: before)
                let name = result.playlist.title
                if result.missed.isEmpty {
                    router.say(draft.isNew ? "Made \(name)" : "Saved \(name)")
                } else {
                    router.say("Made \(name), but the \(result.missed.joined(separator: " and ")) didn't stick")
                }
                dismiss()
                if draft.isNew, draft.opensWhenSaved { router.open(result.playlist) }
            } catch {
                saving = false
                Logger.ui.error("[editor] save failed: \(error.localizedDescription, privacy: .public)")
                router.say(draft.isNew ? "Couldn't make the playlist" : "Couldn't save that")
            }
        }
    }
}
