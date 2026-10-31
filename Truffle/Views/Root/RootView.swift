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
        .sheet(item: Binding(get: { router.addingToPlaylist.map(TrackBatch.init) }, set: { router.addingToPlaylist = $0?.tracks })) { batch in
            AddToPlaylistSheet(tracks: batch.tracks)
                .presentationDetents([.medium, .large])
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
    /// `-TruffleScene mixes|player|albums|icons|stats`: opens straight to a screen, for store screenshots.
    /// With `stats`, `-TruffleScroll months|mostPlayed|habits|dayOne` scrolls down to a card.
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
        default:
            break
        }
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

private struct TrackBatch: Identifiable {
    let tracks: [Track]
    var id: String { tracks.map(\.id).joined(separator: ",") }
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
