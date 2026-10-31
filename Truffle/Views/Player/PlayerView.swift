import SwiftUI
import os

struct PlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var showsQueue = false

    var body: some View {
        Group {
            if let track = player.current {
                content(for: track)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "play.slash")
            }
        }
        .background { PlayerBackdrop(thumb: player.current?.thumb) }
        .sheet(isPresented: $showsQueue) { QueueView() }
        .presentationDragIndicator(.visible)
    }

    /// The top bar spans the screen; below it the cover and the controls share it. On an open
    /// iPhone Duo they take a panel each; on a phone (or a closed Duo) they stack.
    private func content(for track: Track) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
            arrangement(for: track)
        }
    }

    @ViewBuilder
    private func arrangement(for track: Track) -> some View {
#if IPHONE_DUO_LAYOUTS
        if #available(iOS 27.1, *) {
            ArrangementView {
                artwork(for: track)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                controls(for: track)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .arrangementViewStyle(.split)
            .splitArrangementLayoutRatio(0.5)
        } else {
            stacked(for: track)
        }
#else
        stacked(for: track)
#endif
    }

    private func stacked(for track: Track) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                artwork(for: track)
                    .frame(width: min(geometry.size.width - 56, geometry.size.height * 0.48))
                Spacer(minLength: 18)
                controls(for: track)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
            Spacer()
            if let source = player.source {
                VStack(spacing: 1) {
                    Text(source.kind == .shuffleAll ? "TRUE SHUFFLE" : "PLAYING FROM")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(source.kind == .shuffleAll ? "All \(library.trackCount.grouped) Songs" : source.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                if let track = player.current {
                    Button("Add to Playlist…", systemImage: "music.note.list") { router.addingToPlaylist = [track] }
                }
                Button("Shuffle Up Next", systemImage: "shuffle") { player.shuffleUpcoming() }
                Button("Queue", systemImage: "list.bullet") { showsQueue = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("More")
        }
    }

    private func artwork(for track: Track) -> some View {
        ArtworkView(thumb: track.thumb, pixels: 900, cornerRadius: 20)
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.32), radius: 28, y: 16)
            .scaleEffect(player.isPlaying ? 1 : 0.9)
            .animation(.spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
            .id(track.id)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private func controls(for track: Track) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !track.album.isEmpty {
                        Text(track.year.map { "\(track.album) · \(String($0))" } ?? track.album)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                LikeButton(track: track)
            }
            ScrubberView()
            TransportControls()
            HStack {
                RepeatButton()
                Spacer()
                RoutePickerView()
                    .frame(width: 44, height: 44)
                Spacer()
                Button {
                    showsQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Queue")
            }
            .foregroundStyle(.secondary)
            if player.source?.kind == .shuffleAll, let progress = library.shuffleProgress {
                Text("Round \(progress.round) · \(progress.played.grouped) of \(progress.total.grouped) songs, every one equally likely")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct LikeButton: View {
    let track: Track
    @Environment(PlayerEngine.self) private var player
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        let liked = library.isLiked(track)
        Button {
            Task { await player.toggleLike() }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.title2)
                .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: liked)
        .accessibilityLabel(liked ? "Unlike" : "Like")
    }
}

private struct RepeatButton: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Button {
            player.cycleRepeat()
        } label: {
            Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                .font(.title3)
                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Repeat")
        .accessibilityValue(player.repeatMode == .off ? "Off" : player.repeatMode == .all ? "All" : "One")
    }
}

struct TransportControls: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous")
            .frame(maxWidth: .infinity)

            Button {
                player.togglePlayPause()
            } label: {
                Group {
                    if player.isLoading {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 38, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 70, height: 70)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .frame(maxWidth: .infinity)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next")
            .frame(maxWidth: .infinity)
        }
    }
}

struct ScrubberView: View {
    @Environment(PlayerEngine.self) private var player
    @State private var dragging: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let shown = dragging ?? min(player.currentTime, duration)
        VStack(spacing: 4) {
            Slider(value: Binding(get: { shown }, set: { dragging = $0 }), in: 0...duration) { editing in
                if !editing, let target = dragging {
                    player.seek(to: target)
                    dragging = nil
                }
            }
            .accessibilityLabel("Position")
            .accessibilityValue("\(shown.clockString) of \(duration.clockString)")
            HStack {
                Text(shown.clockString)
                Spacer()
                Text("-" + max(0, duration - shown).clockString)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// The cover's colors as a slowly drifting mesh behind the player, like Earmark's.
struct PlayerBackdrop: View {
    let thumb: String?
    @Environment(MusicLibrary.self) private var library
    @Environment(SeasonClock.self) private var season
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colors: [Color]?

    var body: some View {
        let grid = colors ?? Self.fallback(season.theme)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: Self.points(at: t), colors: grid)
                .overlay(scrim)
                .ignoresSafeArea()
        }
        .task(id: thumb) {
            guard let thumb, let client = library.client,
                  let image = await ArtworkCache.shared.image(thumb: thumb, size: 900, client: client),
                  let sampled = Self.gridColors(from: image) else { return }
            withAnimation(.easeInOut(duration: 0.9)) { colors = sampled }
        }
    }

    /// Heavier at the top and bottom, where the text and controls sit.
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: Color(.systemBackground).opacity(0.55), location: 0),
            .init(color: Color(.systemBackground).opacity(0.2), location: 0.4),
            .init(color: Color(.systemBackground).opacity(0.45), location: 0.72),
            .init(color: Color(.systemBackground).opacity(0.7), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private static func fallback(_ theme: SeasonTheme) -> [Color] {
        let c = theme.colors + [theme.accentColor]
        return [c[2], c[3], c[1], c[1], c[2], c[0], c[0], c[1], c[0]]
    }

    static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        let dx = Float(sin(t * 0.22)) * 0.08, dy = Float(cos(t * 0.17)) * 0.08
        let ex = Float(cos(t * 0.13)) * 0.05
        return [
            [0, 0], [0.5 + ex, 0], [1, 0],
            [0, 0.5 - ex], [0.5 + dx, 0.5 + dy], [1, 0.5 + ex],
            [0, 1], [0.5 - ex, 1], [1, 1],
        ]
    }

    /// Samples a cover into a 3×3 grid of colors, nudged toward vibrancy so muddy covers still read as color.
    static func gridColors(from image: UIImage) -> [Color]? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 3
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return (0..<(side * side)).map { index in
            var red = Double(pixels[index * 4]) / 255, green = Double(pixels[index * 4 + 1]) / 255, blue = Double(pixels[index * 4 + 2]) / 255
            let mean = (red + green + blue) / 3
            red = min(1, max(0, mean + (red - mean) * 1.4))
            green = min(1, max(0, mean + (green - mean) * 1.4))
            blue = min(1, max(0, mean + (blue - mean) * 1.4))
            return Color(.sRGB, red: red, green: green, blue: blue)
        }
    }
}
