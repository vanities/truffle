import SwiftUI
import os

struct HomeView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(SeasonClock.self) private var season
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var startingMix: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if sizeClass == .regular {
                        // Wide (an open iPhone Duo, an iPad): the shuffle beside the season's mixes.
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 14) {
                                shuffleCard
                                quickButtons
                            }
                            .frame(maxWidth: .infinity)
                            mixesGrid
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 20)
                    } else {
                        shuffleCard
                            .padding(.horizontal, 20)
                        quickButtons
                            .padding(.horizontal, 20)
                            .id("quick")
                        mixesShelf
                    }
                    if !library.recentlyAdded.isEmpty { recentlyAddedShelf }
                    if !library.playlists.isEmpty { playlistsShelf }
                    StatusFooter()
                        .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
                .background(alignment: .top) { headerBackdrop }
            }
            .scrollIndicators(.hidden)
            // The season's colors run up under the status bar.
            .scrollClipDisabled()
            .refreshable { await library.refresh() }
            .onChange(of: router.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
            }
            }
            .toolbar(.hidden, for: .navigationBar)
            .libraryDestinations()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(season.theme.label)
                .font(.caption.weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.8))
            Text(SeasonCalendar.greeting(for: season.now))
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(season.theme.greeting)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.top, 64)
        .accessibilityElement(children: .combine)
    }

    /// The season's colors behind the top of the screen, fading into the page, with its particles.
    private var headerBackdrop: some View {
        ZStack {
            season.theme.gradient
            SeasonalBackdrop(theme: season.theme)
        }
        .frame(height: 640)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.68),
                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .offset(y: -200)
    }

    // MARK: - Shelves

    private var shuffleCard: some View {
        ShuffleAllCard(theme: season.theme, trackCount: library.trackCount, progress: library.shuffleProgress,
                       isActive: player.source?.kind == .shuffleAll, isPlaying: player.isPlaying,
                       isStarting: startingMix == Mix.shuffleAll.id) {
            start(.shuffleAll)
        }
    }

    private var mixesGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("For \(season.theme.title)").font(.title3.weight(.bold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Array(season.mixes.enumerated()), id: \.element.id) { index, mix in
                    Button {
                        start(mix)
                    } label: {
                        MixCard(mix: mix, theme: season.theme, variant: index, isStarting: startingMix == mix.id,
                                curated: library.curatedPlaylist(for: mix), width: nil)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var quickButtons: some View {
        HStack(spacing: 12) {
            QuickButton(title: Mix.randomAlbum.title, symbol: "square.stack.fill", isStarting: startingMix == Mix.randomAlbum.id) {
                start(.randomAlbum)
            }
            NavigationLink(value: Route.liked) {
                QuickLabel(title: "Liked", detail: library.likedCount > 0 ? library.likedCount.grouped : nil, symbol: "heart.fill")
            }
            .buttonStyle(.plain)
        }
    }

    private var mixesShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "For \(season.theme.title)")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(Array(season.mixes.enumerated()), id: \.element.id) { index, mix in
                        Button {
                            start(mix)
                        } label: {
                            MixCard(mix: mix, theme: season.theme, variant: index, isStarting: startingMix == mix.id,
                                    curated: library.curatedPlaylist(for: mix))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var recentlyAddedShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "Recently Added")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(library.recentlyAdded) { album in
                        NavigationLink(value: Route.album(album)) {
                            AlbumTile(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var playlistsShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "Playlists") {
                NavigationLink("See All", value: Route.playlists)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: Route.playlist(playlist)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(thumb: playlist.thumb, pixels: 400, cornerRadius: 12, placeholderSymbol: "music.note.list")
                                    .frame(width: 140, height: 140)
                                Text(playlist.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(playlist.trackCount.counted("song"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func start(_ mix: Mix) {
        guard startingMix == nil else { return }
        startingMix = mix.id
        Logger.ui.info("[home] start \(mix.title, privacy: .public)")
        Task {
            await player.play(mix, theme: season.theme)
            startingMix = nil
        }
    }
}

/// The true random button: the one thing on the home screen that should be impossible to miss.
struct ShuffleAllCard: View {
    let theme: SeasonTheme
    let trackCount: Int
    let progress: ShuffleProgress?
    let isActive: Bool
    let isPlaying: Bool
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                DriftingGradient(colors: theme.colors + [theme.accentColor])
                Image(systemName: "shuffle")
                    .font(.system(size: 150, weight: .black))
                    .foregroundStyle(.white.opacity(0.12))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 30, y: 40)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Group {
                            if isStarting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: isActive && isPlaying ? "waveform" : "shuffle")
                                    .symbolEffect(.variableColor.iterative, isActive: isActive && isPlaying)
                            }
                        }
                        .font(.system(size: 26, weight: .bold))
                        .frame(width: 58, height: 58)
                        .background(.white.opacity(0.2), in: Circle())
                        Spacer()
                        if isActive {
                            Text(isPlaying ? "PLAYING" : "PAUSED")
                                .font(.caption.weight(.heavy))
                                .tracking(1.2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.white.opacity(0.22), in: Capsule())
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Shuffle All")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text(trackCount > 0 ? "\(trackCount.grouped) songs. No favorites." : "No favorites.")
                        .font(.subheadline.weight(.medium))
                        .opacity(0.9)
                    if let progress, progress.total > 0 {
                        ProgressView(value: Double(progress.played), total: Double(progress.total))
                            .tint(.white)
                            .padding(.top, 4)
                        Text("Round \(progress.round) · \(progress.played.grouped) of \(progress.total.grouped)")
                            .font(.caption.weight(.medium))
                            .opacity(0.8)
                    }
                }
                .padding(22)
                .foregroundStyle(.white)
            }
            .frame(height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: theme.colors[1].opacity(0.45), radius: 24, y: 12)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Shuffle All")
        .accessibilityHint("Every song, no favorites")
    }
}

/// One seasonal mix. Each card takes a different turn through the season's colors.
struct MixCard: View {
    let mix: Mix
    let theme: SeasonTheme
    let variant: Int
    let isStarting: Bool
    /// This year's hand-picked playlist for the theme: its title, one-liner and poster win.
    var curated: Playlist?
    /// Fixed on the phone's shelf; nil fills a grid cell.
    var width: CGFloat? = 168

    private var hasArt: Bool { curated?.thumb != nil || mix.art.flatMap { UIImage(named: "Mix-\($0)") } != nil }

    private var colors: [Color] {
        let base = theme.colors + [theme.accentColor]
        switch mix.kind {
        case .nightDrive: return [Color(red: 0.05, green: 0.06, blue: 0.16), Color(red: 0.2, green: 0.16, blue: 0.45), Color(red: 0.42, green: 0.32, blue: 0.85)]
        case .lastYear: return [base[0], base[3], base[2]]
        case .seasonFavorites: return [base[1], base[0], base[3]]
        default:
            let shift = variant % base.count
            return Array(base[shift...] + base[..<shift])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // The art says it already; the symbol is for cards without art.
                if !hasArt {
                    Image(systemName: mix.symbol)
                        .font(.system(size: 30, weight: .semibold))
                }
                Spacer()
                if isStarting { ProgressView().tint(.white) }
            }
            Spacer(minLength: 0)
            Text(curated?.title ?? mix.title)
                .font(.headline)
                .lineLimit(2)
            Text(curated?.blurb ?? mix.subtitle)
                .font(.caption.weight(.medium))
                .opacity(0.85)
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: width, height: 196, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .foregroundStyle(.white)
        .background {
            let fade = LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.72), location: 1)],
                                      startPoint: .top, endPoint: .bottom)
            if let poster = curated?.thumb {
                ArtworkView(thumb: poster, pixels: 600, cornerRadius: 0)
                    .overlay(fade)
            } else if let art = mix.art, UIImage(named: "Mix-\(art)") != nil {
                Image("Mix-\(art)")
                    .resizable()
                    .scaledToFill()
                    .overlay(fade)
            } else {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: colors[1].opacity(0.35), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
    }
}

private struct QuickButton: View {
    let title: String
    let symbol: String
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            QuickLabel(title: title, detail: nil, symbol: symbol, isStarting: isStarting)
        }
        .buttonStyle(.plain)
    }
}

private struct QuickLabel: View {
    let title: String
    let detail: String?
    let symbol: String
    var isStarting = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isStarting { ProgressView() } else { Image(systemName: symbol).foregroundStyle(.tint) }
            }
            .font(.title3)
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 56)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }
}

/// A slowly drifting mesh of the given colors.
struct DriftingGradient: View {
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: Self.points(at: t), colors: Self.grid(colors))
        }
    }

    private static func grid(_ colors: [Color]) -> [Color] {
        let c = colors.isEmpty ? [.orange] : colors
        let pick = { (i: Int) in c[i % c.count] }
        return [pick(0), pick(1), pick(1), pick(0), pick(2), pick(3), pick(1), pick(3), pick(2)]
    }

    private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        let dx = Float(sin(t * 0.35)) * 0.12, dy = Float(cos(t * 0.27)) * 0.1
        let ex = Float(cos(t * 0.21)) * 0.06
        return [
            [0, 0], [0.5 + ex, 0], [1, 0],
            [0, 0.5 - ex], [0.5 + dx, 0.5 + dy], [1, 0.5 + ex],
            [0, 1], [0.5 - ex, 1], [1, 1],
        ]
    }
}

/// A little press-down spring for cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// How the connection to the server is doing, at the bottom of Home.
struct StatusFooter: View {
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        HStack(spacing: 8) {
            switch library.phase {
            case .connecting:
                ProgressView()
                Text("Finding \(library.serverName)…")
            case .unreachable(let message), .failed(let message):
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(message)
                Spacer()
                Button("Retry") { library.connect(reason: "retry") }
                    .buttonStyle(.glass)
            case .ready:
                Image(systemName: library.endpoint?.kind == .local ? "house.fill" : "globe")
                Text("\(library.serverName) · \(library.endpoint?.kind.label ?? "")")
            case .signedOut:
                EmptyView()
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PlexEndpoint.Kind {
    var label: String {
        switch self {
        case .local: "home network"
        case .remote: "over the internet"
        case .relay: "through Plex's relay"
        }
    }
}
