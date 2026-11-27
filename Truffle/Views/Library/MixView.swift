import SwiftUI
import os

/// A mix Truffle made: its cover, when it was made, and its songs in the order they were drawn. It stays
/// that way until Regenerate draws it again (`MusicLibrary.madeMix`).
struct MixView: View {
    let mix: Mix
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(SeasonClock.self) private var season
    @Environment(AppRouter.self) private var router
    @State private var making = false

    private var saved: SavedMix? { library.savedMix(for: mix) }
    private var tracks: [Track] { saved?.tracks ?? [] }
    private var source: PlaySource { PlaySource(kind: .mix, title: mix.title, id: mix.id) }

    var body: some View {
        List {
            VStack(spacing: 14) {
                MixCover(mix: mix, theme: season.theme)
                    .headerCoverSize()
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                VStack(spacing: 4) {
                    Text(mix.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(recipe)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                PlayShuffleButtons(source: source, play: { player.play(tracks, source: source) },
                                   shuffle: { player.play(tracks, source: source, shuffled: true) })
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
            }
        }
        .listStyle(.plain)
        .measuresHeaderCover()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Regenerate", systemImage: "arrow.clockwise") { Task { await make(regenerate: true) } }
                    .disabled(making)
            }
        }
        .overlay {
            if making && tracks.isEmpty {
                ProgressView()
            } else if !making && tracks.isEmpty {
                ContentUnavailableView("Came Up Empty", systemImage: mix.symbol, description: Text("Nothing in your library fits yet. Regenerate tries again."))
            }
        }
        .task(id: mix.id) {
            if saved == nil { await make(regenerate: false) }
        }
    }

    /// How it was put together, since nobody picked it.
    private var recipe: String {
        switch mix.kind {
        case .lastYear: "What you played around now in other years"
        case .seasonFavorites: "What you've played most this season"
        default: "Drawn at random from your library by mood"
        }
    }

    private var details: String {
        guard let saved, !saved.tracks.isEmpty else { return making ? "Making it…" : "" }
        return [saved.tracks.count.counted("song"), saved.tracks.reduce(0) { $0 + $1.duration }.shortDurationString,
                "Made \(saved.madeAt.formatted(date: .abbreviated, time: .omitted))"].joined(separator: " · ")
    }

    private func make(regenerate: Bool) async {
        making = true
        defer { making = false }
        do {
            let made = try await library.madeMix(mix, theme: season.theme, regenerate: regenerate)
            Logger.ui.info("[ui] mix \(mix.title, privacy: .public): \(made.tracks.count) songs\(regenerate ? ", regenerated" : "", privacy: .public)")
        } catch {
            Logger.ui.error("[ui] mix \(mix.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            router.say("\(mix.title) didn't load. Try again?")
        }
    }
}

/// A mix's own art, or the season's colors with its symbol when it has none.
struct MixCover: View {
    let mix: Mix
    let theme: SeasonTheme

    var body: some View {
        Group {
            if let art = mix.art, UIImage(named: "Mix-\(art)") != nil {
                Image(decorative: "Mix-\(art)")
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Image(systemName: mix.symbol)
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}
