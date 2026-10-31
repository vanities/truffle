import SwiftUI
import os

struct RootView: View {
    enum AppTab: Hashable {
        case home, library, stats, settings, search
    }

    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(SeasonClock.self) private var season
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .home

    var body: some View {
        @Bindable var router = router
        Group {
            if library.phase == .signedOut {
                SignInView()
                    .transition(.opacity)
            } else {
                tabs
            }
        }
        .animation(.smooth, value: library.phase == .signedOut)
        .tint(season.theme.accentColor)
        .modifier(PlayerPresentation(isPresented: $router.showsPlayer))
        .sheet(item: Binding(get: { router.sheet }, set: { if $0 == nil { router.dismissSheet() } })) { sheet in
            switch sheet {
            case .addToPlaylist(let tracks):
                AddToPlaylistSheet(tracks: tracks)
                    .presentationDetents([.medium, .large])
            case .editPlaylist(let draft):
                PlaylistEditorView(draft: draft)
            }
        }
        .overlay(alignment: .top) { toast }
        .onChange(of: player.errorMessage) { _, message in
            guard let message else { return }
            router.say(message)
            player.clearError()
        }
        // `initial`: a launch starts already active, so there's no change to see.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            season.refresh()
            AppIconSwitcher.apply(settings: settings, theme: season.theme)
        }
        .onChange(of: settings.appIcon) { AppIconSwitcher.apply(settings: settings, theme: season.theme) }
        #if DEBUG
        .task { await openDebugScene() }
        #endif
        .onChange(of: settings.seasonalIcon) { AppIconSwitcher.apply(settings: settings, theme: season.theme) }
        .onChange(of: library.phase == .signedOut) { _, signedOut in
            // Signing in again (after signing out from Settings) starts at Home.
            if signedOut { tab = .home }
        }
    }

    #if DEBUG
    /// `-TruffleScene mixes|player|albums|icons|stats|settings|album`: opens straight to a screen, for
    /// store screenshots; `car` and `shuffle` run checks that can't be tapped through in the simulator.
    /// With `stats`, `-TruffleScroll months|mostPlayed|habits|dayOne` scrolls down to a card.
    /// Playlists: `playlists`, `playlistNew` (the empty editor), `playlistFilled` (the editor with a
    /// name, cover and songs; add `-TrufflePickerQuery light` for Add Songs), `playlistCreated` (saves
    /// that draft for real and opens it), `addToNewPlaylist` (Add to Playlist handing its songs to the
    /// editor), `liked`, `artists`, `playlist` (the first of yours). A sort comes from launch arguments:
    /// `-sort.liked mostPlayed`.
    private func openDebugScene() async {
        guard let scene = UserDefaults.standard.string(forKey: "TruffleScene") else { return }
        try? await Task.sleep(for: .seconds(4))
        Logger.ui.info("[debug] scene \(scene, privacy: .public)")
        switch scene {
        case "mixes":
            router.scrollTarget = "quick"
        case "player":
            if let mix = season.mixes.first { await player.play(mix, theme: season.theme) }
            try? await Task.sleep(for: .seconds(2))
            router.showsPlayer = true
        case "albums":
            tab = .library
            router.libraryPath = [.albums]
        case "icons":
            tab = .settings
            try? await Task.sleep(for: .seconds(1))
            router.scrollTarget = "appIcon"
        case "stats":
            tab = .stats
            guard let target = UserDefaults.standard.string(forKey: "TruffleScroll") else { break }
            try? await Task.sleep(for: .seconds(3))
            router.scrollTarget = target
        case "playlists", "playlistNew", "playlistFilled", "playlistCreated":
            tab = .library
            router.libraryPath = [.playlists]
            try? await Task.sleep(for: .seconds(1))
            if scene == "playlistNew" {
                router.editingPlaylist = .new(opensWhenSaved: true)
            } else if scene != "playlists" {
                let draft = await debugDraft()
                if scene == "playlistFilled" {
                    router.editingPlaylist = draft
                } else {
                    do {
                        let result = try await library.save(draft)
                        router.say("Made \(result.playlist.title)")
                        router.open(result.playlist)
                    } catch {
                        Logger.ui.error("[debug] save failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        case "addToNewPlaylist":
            let songs = Array(((try? await library.likedTracks()) ?? []).prefix(3))
            router.addingToPlaylist = songs
            try? await Task.sleep(for: .seconds(2))
            router.startNewPlaylist(with: songs)
        case "liked", "artists":
            tab = .library
            router.libraryPath = [scene == "liked" ? .liked : .artists]
        case "playlist":
            tab = .library
            if let mine = library.playlists.first(where: { !$0.isSmart }) { router.libraryPath = [.playlists, .playlist(mine)] }
        case "settings":
            // `-TruffleScroll shuffle|car|holidays|appIcon`
            tab = .settings
            try? await Task.sleep(for: .seconds(1))
            router.scrollTarget = UserDefaults.standard.string(forKey: "TruffleScroll")
        case "album":
            // `-TruffleAlbum "A Low Tide Christmas"`
            let title = UserDefaults.standard.string(forKey: "TruffleAlbum")
            guard let album = library.albums.first(where: { $0.title == title }) else { break }
            tab = .library
            router.libraryPath = [.albums, .album(album)]
        case "car":
            await connectCarTwice()
        case "shuffle":
            await skipThroughShuffleAll()
        default:
            break
        }
    }

    /// "Night Drive": a name, a description, three songs a search for "light" finds and two liked ones,
    /// and a cover cut like a photo would be: the top of a demo cover (no lettering) as a wide image,
    /// which `CoverImage` squares.
    private func debugDraft() async -> PlaylistDraft {
        let found = ((try? await library.search("light", limit: 40))?.tracks ?? []).prefix(3)
        let liked = ((try? await library.likedTracks()) ?? []).filter { song in !found.contains { $0.id == song.id } }.prefix(2)
        var draft = PlaylistDraft.new(with: Array(found) + Array(liked), opensWhenSaved: true)
        draft.title = "Night Drive"
        draft.summary = "Windows down, volume up."
        if let url = Bundle.main.url(forResource: "DemoLibrary", withExtension: nil)?.appending(path: "covers/neon-drive.jpg"),
           let image = UIImage(contentsOfFile: url.path())?.cgImage,
           let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height * 7 / 10)),
           let photo = UIImage(cgImage: top).jpegData(compressionQuality: 0.95) {
            draft.cover = CoverImage.squareJPEG(from: photo)
        }
        Logger.ui.info("[debug] draft with \(draft.songs.count) song(s), cover \(draft.cover?.count ?? 0)B")
        return draft
    }

    /// `-TruffleScene car`: what CarPlaySceneDelegate does when the car connects, without the CarPlay
    /// window (it can't be scripted): a connection, the same connection announced again, then a new one.
    private func connectCarTwice() async {
        var autoplay = CarAutoplay()
        let showNowPlaying = { Logger.ui.info("[debug] the car shows Now Playing") }
        autoplay.carConnected(environment: .shared, showNowPlaying: showNowPlaying)
        try? await Task.sleep(for: .seconds(5))
        autoplay.carConnected(environment: .shared, showNowPlaying: showNowPlaying)
        autoplay.carDisconnected()
        autoplay.carConnected(environment: .shared, showNowPlaying: showNowPlaying)
    }

    /// `-TruffleScene shuffle [-TruffleSteps n]`: Shuffle All, then Next every 300 ms for a round's worth
    /// of songs, stopping when a holiday song plays. Shows what the shuffle holds back on `-TruffleDate`.
    private func skipThroughShuffleAll() async {
        await player.shuffleAll()
        let steps = UserDefaults.standard.integer(forKey: "TruffleSteps")
        for step in 1...max(1, steps > 0 ? steps : library.trackCount + 5) {
            try? await Task.sleep(for: .milliseconds(300))
            if let track = player.current, HolidayMusic.isHoliday(track) {
                Logger.ui.info("[debug] step \(step): holiday song \"\(track.title, privacy: .public)\" is playing")
                return
            }
            player.next()
        }
        Logger.ui.info("[debug] skipped through \(steps > 0 ? steps : self.library.trackCount + 5) songs; no holiday song played")
    }
    #endif

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab("Stats", systemImage: "chart.bar", value: AppTab.stats) {
                StatsView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(MiniPlayerAccessory(isEnabled: player.hasTrack) { router.showsPlayer = true })
    }

    @ViewBuilder
    private var toast: some View {
        if let message = router.toast {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { router.toast = nil }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// A sheet on a phone; full screen where there's room (iPad, an open iPhone Duo), so the player's
/// two-panel layout gets the whole display.
private struct PlayerPresentation: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular || Self.isDuo {
            content.fullScreenCover(isPresented: $isPresented) { PlayerView() }
        } else {
            content.sheet(isPresented: $isPresented) { PlayerView() }
        }
    }

    private static var isDuo: Bool {
#if IPHONE_DUO_LAYOUTS
        if #available(iOS 27.1, *) { return true }
#endif
        return false
    }
}

private struct MiniPlayerAccessory: ViewModifier {
    let isEnabled: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) { MiniPlayerView(open: open) }
        } else if isEnabled {
            content.tabViewBottomAccessory { MiniPlayerView(open: open) }
        } else {
            content
        }
    }
}
