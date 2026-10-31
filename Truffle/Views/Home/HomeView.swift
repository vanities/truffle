import SwiftUI
import os

struct HomeView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(SeasonClock.self) private var season
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var startingMix: String?
    /// Whether any of the header's backdrop is still on screen (the cards with props sit inside it).
    @State private var backdropInView = true
    @ScaledMetric(relativeTo: .largeTitle) private var greetingSize: CGFloat = 38

    /// The backdrop starts this far above the content (behind the status bar) and runs at least this tall.
    private static let backdropRise: CGFloat = 200
    private static let backdropHeight: CGFloat = 640
    /// Where the backdrop starts fading into the page, as a share of its height.
    private static let backdropFade = 0.68
    @State private var headerHeight: CGFloat = 0

    /// Tall enough that the header's white words never reach the fade, however big the text.
    private var backdropHeight: CGFloat {
        max(Self.backdropHeight, (headerHeight + Self.backdropRise) / Self.backdropFade + 24)
    }

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
                    if !library.recentlyAdded.isEmpty { albumShelf("Recently Added", library.recentlyAdded) }
                    if !library.recentlyPlayed.isEmpty { albumShelf("Recently Played", library.recentlyPlayed) }
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
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < backdropHeight - Self.backdropRise
            } action: { _, inView in
                backdropInView = inView
            }
            // The header's sky and the props on its cards rest once they're scrolled away or under the player.
            .environment(\.seasonalInView, backdropInView && !router.showsPlayer)
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
            Text(SeasonCalendar.greeting(for: season.now))
                .font(.system(size: greetingSize, weight: .heavy, design: .rounded))
            Text(season.theme.greeting)
                .font(.title3.weight(.medium))
        }
        .foregroundStyle(.white)
        // Fireflies, sunbeams and the moon drift behind the words; the shadow keeps them readable.
        .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
        .padding(.horizontal, 20)
        .padding(.top, 64)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The season's colors behind the top of the screen, fading into the page, with its particles. The
    /// open sky starts where the content does, just under the status bar.
    private var headerBackdrop: some View {
        ZStack {
            season.theme.gradient
            SeasonalBackdrop(theme: season.theme, skyTop: Self.backdropRise)
        }
        .frame(height: backdropHeight)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: Self.backdropFade),
                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .offset(y: -Self.backdropRise)
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
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Array(season.mixes.enumerated()), id: \.element.id) { index, mix in
                    Button {
                        start(mix)
                    } label: {
                        MixCard(mix: mix, theme: season.theme, variant: index, isStarting: startingMix == mix.id,
                                curated: library.curatedPlaylist(for: mix), width: nil)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityInputLabels([library.curatedPlaylist(for: mix)?.title ?? mix.title])
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
            .accessibilityInputLabels(["Liked", "Liked Songs"])
        }
    }

    @ViewBuilder
    private var mixesShelf: some View {
        if typeSize.isAccessibilitySize {
            // Big text gets the cards one under another, full width, instead of a sideways shelf.
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: "For \(season.theme.title)")
                ForEach(Array(season.mixes.enumerated()), id: \.element.id) { index, mix in
                    Button {
                        start(mix)
                    } label: {
                        MixCard(mix: mix, theme: season.theme, variant: index, isStarting: startingMix == mix.id,
                                curated: library.curatedPlaylist(for: mix), width: nil)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityInputLabels([library.curatedPlaylist(for: mix)?.title ?? mix.title])
                    .padding(.horizontal, 20)
                }
            }
        } else {
            shelfOfMixes
        }
    }

    private var shelfOfMixes: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "For \(season.theme.title)")
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(season.mixes.enumerated()), id: \.element.id) { index, mix in
                        Button {
                            start(mix)
                        } label: {
                            MixCard(mix: mix, theme: season.theme, variant: index, isStarting: startingMix == mix.id,
                                    curated: library.curatedPlaylist(for: mix))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityInputLabels([library.curatedPlaylist(for: mix)?.title ?? mix.title])
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            // Pumpkins and snow rest on the cards' top edges, above the shelf's bounds.
            .scrollClipDisabled()
        }
    }

    private func albumShelf(_ title: String, _ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
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
                                    .lineLimit(1, atAccessibilitySizes: nil)
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
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 34
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
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
                            .background(.black.opacity(0.3), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
                Text("Shuffle All")
                    .font(.system(size: titleSize, weight: .heavy, design: .rounded))
                Text(trackCount > 0 ? "\(trackCount.grouped) songs. No favorites." : "No favorites.")
                    .font(.subheadline.weight(.semibold))
                if let progress, progress.total > 0 {
                    ProgressView(value: Double(progress.played), total: Double(progress.total))
                        .tint(.white)
                        .padding(.top, 4)
                    Text("Round \(progress.round) · \(progress.played.grouped) of \(progress.total.grouped)")
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(22)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            // At the accessibility text sizes the card grows with its words instead of cutting them off.
            .frame(height: typeSize.isAccessibilitySize ? nil : 236)
            .background {
                ZStack(alignment: .topTrailing) {
                    DriftingGradient(colors: theme.colors + [theme.accentColor])
                    // The seasons' brightest colors (Halloween's orange, summer's yellow) wash out white
                    // text; the shade under the words keeps them readable.
                    LinearGradient(stops: [.init(color: .clear, location: 0.2),
                                           .init(color: .black.opacity(contrast == .increased ? 0.62 : 0.42), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "shuffle")
                        .font(.system(size: 150, weight: .black))
                        .foregroundStyle(.white.opacity(0.12))
                        .rotationEffect(.degrees(-12))
                        .offset(x: 30, y: 40)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: theme.colors[1].opacity(0.45), radius: 24, y: 12)
            .seasonalPerch(theme, spot: .shuffleAll, cornerRadius: 30)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Shuffle All")
        .accessibilityValue(spokenState)
        .accessibilityHint("Every song, no favorites")
    }

    /// What the card shows besides its name: playing or paused, the songs, how far through the round.
    private var spokenState: String {
        var parts: [String] = []
        if isActive { parts.append(isPlaying ? "Playing" : "Paused") }
        if trackCount > 0 { parts.append("\(trackCount.grouped) songs") }
        if let progress, progress.total > 0 {
            parts.append("round \(progress.round), \(progress.played.grouped) of \(progress.total.grouped) played")
        }
        return parts.joined(separator: ", ")
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

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
                        .accessibilityHidden(true)
                }
                Spacer()
                if isStarting { ProgressView().tint(.white) }
            }
            Spacer(minLength: 0)
            Text(curated?.title ?? mix.title)
                .font(.headline)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            Text(curated?.blurb ?? mix.subtitle)
                .font(.caption.weight(.semibold))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .padding(16)
        // At the accessibility text sizes the card grows with its words instead of cutting them off.
        .frame(width: width, height: typeSize.isAccessibilitySize ? nil : 196, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .foregroundStyle(.white)
        .background {
            // Light art and the brighter season colors both need the shade under white words, and it has
            // to be dark already where the title starts.
            let fade = LinearGradient(stops: [.init(color: .clear, location: 0.15),
                                              .init(color: .black.opacity(contrast == .increased ? 0.75 : 0.6), location: 0.5),
                                              .init(color: .black.opacity(contrast == .increased ? 0.9 : 0.8), location: 1)],
                                      startPoint: .top, endPoint: .bottom)
            Group {
                if let poster = curated?.thumb {
                    ArtworkView(thumb: poster, pixels: 600, cornerRadius: 0)
                } else if let art = mix.art, UIImage(named: "Mix-\(art)") != nil {
                    Image(decorative: "Mix-\(art)")
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay(fade)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: colors[1].opacity(0.35), radius: 12, y: 6)
        .seasonalPerch(theme, spot: .mix(variant), cornerRadius: 24)
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
                if isStarting { ProgressView() } else { Image(systemName: symbol).foregroundStyle(.tint).accessibilityHidden(true) }
            }
            .font(.title3)
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    // Gray on the glass is too faint; a lighter black or white isn't.
                    Text(detail).font(.caption).foregroundStyle(.primary.opacity(0.78))
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

/// A little press-down spring for cards; with Reduce Motion, a dim instead.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.75 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
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
