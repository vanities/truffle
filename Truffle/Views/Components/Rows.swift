import SwiftUI

struct TrackRow: View {
    let track: Track
    /// Shows the track number instead of artwork (an album's own list).
    var number: Int?
    var showsArtist = true
    @Environment(PlayerEngine.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        // At the accessibility text sizes the heart and the time go under the words, so the words get the
        // row's width instead of a sliver of it.
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24)
            } else {
                ArtworkView(thumb: track.thumb, pixels: 120, cornerRadius: 6)
                    .frame(width: 46, height: 46)
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    words
                    HStack(spacing: 12) { trailing }
                }
            } else {
                words
                Spacer(minLength: 8)
                trailing
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1, atAccessibilitySizes: nil)
            if showsArtist {
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1, atAccessibilitySizes: nil)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if library.isLiked(track) {
            Image(systemName: "heart.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .accessibilityLabel("Liked")
        }
        // The playing song shows a waveform, not just its tint, whether it's playing or paused.
        if isCurrent {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityLabel(player.isPlaying ? "Now playing" : "Paused")
        } else {
            Text(track.duration.clockString)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
                .accessibilityLabel(track.duration.spokenDuration)
        }
    }
}

struct AlbumTile: View {
    let album: Album
    var width: CGFloat = 156
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Wider at the accessibility text sizes, so a title's longest word still fits on a line.
    private var tileWidth: CGFloat { typeSize.isAccessibilitySize ? max(width, 300) : width }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(thumb: album.thumb, pixels: 400, cornerRadius: 12)
                .frame(width: tileWidth, height: tileWidth)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1, atAccessibilitySizes: nil)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1, atAccessibilitySizes: nil)
        }
        .frame(width: tileWidth, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Album grids' columns: one tile across at the accessibility text sizes.
func albumColumns(_ typeSize: DynamicTypeSize) -> [GridItem] {
    [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 300 : 150), spacing: 16)]
}

struct ArtistRow: View {
    let artist: Artist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(thumb: artist.thumb, pixels: 120, circle: true, placeholderSymbol: "music.mic")
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.title).lineLimit(1, atAccessibilitySizes: nil)
                if let count = artist.albumCount {
                    Text(count.counted("album"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
    }
}

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(thumb: playlist.thumb, pixels: 120, cornerRadius: 6, placeholderSymbol: "music.note.list")
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(playlist.title).lineLimit(1, atAccessibilitySizes: nil)
                    if playlist.isSmart {
                        Image(systemName: "gearshape.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Smart playlist")
                    }
                }
                Text(playlist.trackCount.counted("song"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
    }
}

/// A section title with an optional trailing link, for the home screen's shelves.
struct ShelfHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
    }
}

extension ShelfHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        trailing = EmptyView()
    }
}

/// Play and Shuffle, side by side, at the top of an album, artist or playlist.
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void
    @Environment(\.onTintColor) private var onTint
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side there's only room for "P-lay" at the accessibility text sizes.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(onTint)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }
}
