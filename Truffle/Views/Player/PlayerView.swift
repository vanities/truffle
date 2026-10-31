import SwiftUI
import os

struct PlayerView: View {
    /// The quieter text over the cover's colors. iOS's gray takes on the colors behind it and fades on the
    /// brighter covers; a lighter black or white keeps its contrast.
    static let quiet = Color.primary.opacity(0.72)

    @Environment(PlayerEngine.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
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
        // The split gives the controls half the height, which the largest text overflows; it scrolls instead.
        if #available(iOS 27.1, *), !typeSize.isAccessibilitySize {
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
            if typeSize.isAccessibilitySize {
                // Big text takes the room: a smaller cover, and the page scrolls.
                ScrollView {
                    VStack(spacing: 18) {
                        artwork(for: track)
                            .frame(width: min(geometry.size.width - 56, geometry.size.height * 0.3))
                        controls(for: track)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                }
            } else {
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
    }

    /// Close, where it's playing from, and More. At the accessibility text sizes the source gets its own
    /// line under the buttons instead of a narrow gap between them.
    private var topBar: some View {
        VStack(spacing: 10) {
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
                .accessibilityInputLabels(["Close", "Dismiss"])
                Spacer()
                if !typeSize.isAccessibilitySize { sourceLabel }
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
                .accessibilityInputLabels(["More", "Menu", "Options"])
            }
            if typeSize.isAccessibilitySize { sourceLabel }
        }
    }

    @ViewBuilder
    private var sourceLabel: some View {
        if let source = player.source {
            VStack(spacing: 1) {
                Text(source.kind == .shuffleAll ? "TRUE SHUFFLE" : "PLAYING FROM")
                    .font(.caption2.weight(.heavy))
                    .tracking(1.2)
                    .foregroundStyle(Self.quiet)
                Text(source.kind == .shuffleAll ? "All \(library.trackCount.grouped) Songs" : source.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1, atAccessibilitySizes: nil)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(source.kind == .shuffleAll ? "True shuffle of all \(library.trackCount.grouped) songs"
                                                           : "Playing from \(source.title)")
        }
    }

    private func artwork(for track: Track) -> some View {
        ArtworkView(thumb: track.thumb, pixels: 900, cornerRadius: 20)
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.32), radius: 28, y: 16)
            // Paused, the cover shrinks back; with Reduce Motion it dims instead, and songs change by a fade.
            .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.9)
            .opacity(reduceMotion && !player.isPlaying ? 0.7 : 1)
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
            .id(track.id)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
    }

    private func controls(for track: Track) -> some View {
        VStack(spacing: 16) {
            // At the accessibility text sizes the heart goes under the words, which get the full width.
            let titleRow = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                                        : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            titleRow {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1, atAccessibilitySizes: nil)
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(Self.quiet)
                        .lineLimit(1, atAccessibilitySizes: nil)
                    if !track.album.isEmpty {
                        Text(track.year.map { "\(track.album) · \(String($0))" } ?? track.album)
                            .font(.footnote)
                            .foregroundStyle(Self.quiet)
                            .lineLimit(1, atAccessibilitySizes: nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([track.title, track.artist, track.album, track.year.map { String($0) } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: ", "))
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Queue")
                .accessibilityInputLabels(["Queue", "Up Next"])
            }
            .foregroundStyle(.secondary)
            if player.source?.kind == .shuffleAll, let progress = library.shuffleProgress {
                Text("Round \(progress.round) · \(progress.played.grouped) of \(progress.total.grouped)")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let liked = library.isLiked(track)
        Button {
            Task { await player.toggleLike() }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.title2)
                .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: reduceMotion ? false : liked)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: liked)
        .accessibilityLabel("Like")
        .accessibilityAddTraits(liked ? .isSelected : [])
        .accessibilityInputLabels(["Like", "Heart", "Love"])
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
                .background {
                    // On isn't only a color: it sits in a circle.
                    if player.repeatMode != .off { Circle().fill(.tint.opacity(0.18)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Repeat")
        .accessibilityValue(player.repeatMode == .off ? "Off" : player.repeatMode == .all ? "All" : "One")
    }
}

struct TransportControls: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.onTintColor) private var onTint

    var body: some View {
        HStack {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous")
            .accessibilityInputLabels(["Previous", "Back", "Previous Song"])
            .frame(maxWidth: .infinity)

            Button {
                player.togglePlayPause()
            } label: {
                Group {
                    if player.isLoading {
                        ProgressView().controlSize(.large).tint(onTint)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(onTint)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 70, height: 70)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityInputLabels([player.isPlaying ? "Pause" : "Play", "Play Pause"])
            .frame(maxWidth: .infinity)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next")
            .accessibilityInputLabels(["Next", "Skip", "Next Song"])
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
            HStack {
                Text(shown.clockString)
                Spacer()
                Text("-" + max(0, duration - shown).clockString)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(PlayerView.quiet)
            .overlay {
                if player.stream == .dataSaver {
                    Text("DATA SAVER")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(PlayerView.quiet)
                }
            }
        }
        // One element for the bar and both times ("Position, 1:23 of 4:05"). Swiping up or down seeks 15
        // seconds at once instead of going through the slider, which only seeks when a drag ends.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue("\(shown.clockString) of \(duration.clockString)\(player.stream == .dataSaver ? ", Data Saver" : "")")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.seek(to: min(duration, shown + 15))
            case .decrement: player.seek(to: max(0, shown - 15))
            @unknown default: break
            }
        }
    }
}

/// The cover's colors as a slowly drifting mesh behind the player, like Earmark's.
struct PlayerBackdrop: View {
    let thumb: String?
    @Environment(MusicLibrary.self) private var library
    @Environment(SeasonClock.self) private var season
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
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

    /// Heavier at the top and bottom, where the text and controls sit: a cover's brightest colors can
    /// come through right behind the gray text, so those parts are mostly page.
    private var scrim: some View {
        let strength = contrast == .increased ? 1.15 : 1
        return LinearGradient(stops: [
            .init(color: Color(.systemBackground).opacity(min(1, 0.72 * strength)), location: 0),
            .init(color: Color(.systemBackground).opacity(0.25), location: 0.35),
            .init(color: Color(.systemBackground).opacity(min(1, 0.72 * strength)), location: 0.6),
            .init(color: Color(.systemBackground).opacity(min(1, 0.86 * strength)), location: 1),
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
