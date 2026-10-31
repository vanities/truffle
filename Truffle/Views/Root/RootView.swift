import SwiftUI
import os

struct RootView: View {
    enum AppTab: Hashable {
        case home, library, settings, search
    }

    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(SeasonClock.self) private var season
    @Environment(AppRouter.self) private var router
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { season.refresh() }
        }
        .onChange(of: library.phase == .signedOut) { _, signedOut in
            // Signing in again (after signing out from Settings) starts at Home.
            if signedOut { tab = .home }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryView()
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
