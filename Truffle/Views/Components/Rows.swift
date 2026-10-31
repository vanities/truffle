import SwiftUI

struct TrackRow: View {
    let track: Track
    /// Shows the track number instead of artwork (an album's own list).
    var number: Int?
    var showsArtist = true
    @Environment(PlayerEngine.self) private var player
    @Environment(MusicLibrary.self) private var library

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24)
            } else {
                ArtworkView(thumb: track.thumb, pixels: 120, cornerRadius: 6)
                    .frame(width: 46, height: 46)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if showsArtist {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if library.isLiked(track) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Liked")
            }
            if isCurrent, player.isPlaying {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .foregroundStyle(.tint)
                    .frame(width: 40)
            } else {
                Text(track.duration.clockString)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct AlbumTile: View {
    let album: Album
    var width: CGFloat = 156

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(thumb: album.thumb, pixels: 400, cornerRadius: 12)
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ArtistRow: View {
    let artist: Artist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(thumb: artist.thumb, pixels: 120, circle: true, placeholderSymbol: "music.mic")
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.title).lineLimit(1)
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
                    Text(playlist.title).lineLimit(1)
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

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
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
