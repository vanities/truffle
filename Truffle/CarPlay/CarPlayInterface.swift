import CarPlay
import Foundation
import UIKit
import os

/// The car: a Home grid of big buttons (Shuffle All first), Playlists, and Library. Now Playing adds
/// back 15, the heart and repeat, and the album name opens the album. Nothing else to read or reach for
/// while driving.
@MainActor
final class CarPlayInterface: NSObject, CPNowPlayingTemplateObserver {
    /// The car's screen while it's connected, so Siri and Shortcuts can bring up Now Playing the way the
    /// car's own buttons do.
    private(set) static weak var current: CarPlayInterface?

    private let interfaceController: CPInterfaceController
    private let environment: AppEnvironment
    private var homeTemplate: CPGridTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var observing = false
    private var starting: String?

    private var library: MusicLibrary { environment.library }
    private var player: PlayerEngine { environment.player }
    private var season: SeasonClock { environment.season }

    init(interfaceController: CPInterfaceController, environment: AppEnvironment) {
        self.interfaceController = interfaceController
        self.environment = environment
        super.init()
    }

    func start() {
        let home = CPGridTemplate(title: "Truffle", gridButtons: homeButtons())
        home.tabTitle = "Home"
        home.tabImage = UIImage(systemName: "house.fill")
        let playlists = CPListTemplate(title: "Playlists", sections: [])
        playlists.tabTitle = "Playlists"
        playlists.tabImage = UIImage(systemName: "music.note.list")
        playlists.emptyViewTitleVariants = ["No playlists yet"]
        let libraryList = CPListTemplate(title: "Library", sections: [])
        libraryList.tabTitle = "Library"
        libraryList.tabImage = UIImage(systemName: "square.stack.fill")
        libraryList.emptyViewTitleVariants = ["Finding Plex…"]
        homeTemplate = home
        playlistsTemplate = playlists
        libraryTemplate = libraryList
        refreshLists()
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: [home, playlists, libraryList]), animated: true, completion: nil)
        configureNowPlaying()
        observing = true
        observeLibrary()
        observeSeason()
        observeTrack()
        Self.current = self
        Logger.carplay.info("[carplay] started with \(self.library.playlists.count) playlists, \(self.library.albums.count) albums")
    }

    func stop() {
        observing = false
        CPNowPlayingTemplate.shared.remove(self)
        if Self.current === self { Self.current = nil }
    }

    // MARK: - Home

    private func homeButtons() -> [CPGridButton] {
        let theme = season.theme
        var mixes: [Mix] = [.shuffleAll, .liked]
        mixes += season.mixes
        mixes.append(.randomAlbum)
        return mixes.prefix(CPGridTemplateMaximumItems).map { mix in
            CPGridButton(titleVariants: [mix.title, mix.shortTitle], image: Self.gridImage(mix, theme: theme)) { [weak self] _ in
                MainActor.assumeIsolated { self?.start(mix) }
            }
        }
    }

    /// A colored symbol: CarPlay draws template images in one color, and the season's palette
    /// reads better at a glance.
    private static func gridImage(_ mix: Mix, theme: SeasonTheme) -> UIImage {
        let color: UIColor = switch mix.kind {
        case .shuffleAll: UIColor(theme.accentColor)
        case .liked: UIColor(red: 1, green: 0.32, blue: 0.42, alpha: 1)
        case .nightDrive: UIColor(red: 0.55, green: 0.5, blue: 1, alpha: 1)
        default: UIColor(theme.colors[2])
        }
        let config = UIImage.SymbolConfiguration(pointSize: 42, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [color]))
        return (UIImage(systemName: mix.symbol, withConfiguration: config) ?? UIImage()).withRenderingMode(.alwaysOriginal)
    }

    private func start(_ mix: Mix) {
        guard starting == nil else { return }
        starting = mix.id
        Logger.carplay.info("[carplay] start \(mix.title, privacy: .public)")
        showNowPlaying()
        Task {
            await player.play(mix, theme: season.theme)
            starting = nil
        }
    }

    // MARK: - Lists

    private func refreshLists() {
        let sw = Stopwatch()
        let limit = CPListTemplate.maximumItemCount

        var playlistItems: [CPListItem] = [listItem(title: "Liked Songs", detail: library.likedCount.counted("song"),
                                                    symbol: "heart.fill") { [weak self] in self?.start(.liked) }]
        for playlist in library.playlists.prefix(limit - 1) {
            let item = listItem(title: playlist.title, detail: playlist.trackCount.counted("song"), symbol: "music.note.list") { [weak self] in
                self?.open(playlist)
            }
            loadArtwork(playlist.thumb, into: item)
            playlistItems.append(item)
        }
        playlistsTemplate?.updateSections([CPListSection(items: playlistItems)])

        var sections: [CPListSection] = []
        let recent = library.recentlyAdded.prefix(12).map { album in
            let item = listItem(title: album.title, detail: album.artist, symbol: "square.stack.fill") { [weak self] in self?.open(album) }
            loadArtwork(album.thumb, into: item)
            return item
        }
        if !recent.isEmpty { sections.append(CPListSection(items: Array(recent), header: "Recently Added", sectionIndexTitle: nil)) }
        var remaining = limit - recent.count
        let byLetter = Dictionary(grouping: library.artists) { String($0.title.prefix(1)).uppercased() }
        for letter in byLetter.keys.sorted() where remaining > 0 && sections.count < CPListTemplate.maximumSectionCount {
            let artists = Array((byLetter[letter] ?? []).prefix(remaining))
            remaining -= artists.count
            let items = artists.map { artist in
                listItem(title: artist.title, detail: artist.albumCount.map { $0.counted("album") }, symbol: "music.mic") { [weak self] in
                    self?.open(artist)
                }
            }
            sections.append(CPListSection(items: items, header: letter, sectionIndexTitle: letter))
        }
        libraryTemplate?.updateSections(sections)
        Logger.carplay.debug("[carplay] lists refreshed in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    private func listItem(title: String, detail: String?, symbol: String, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: UIImage(systemName: symbol))
        item.handler = { _, completion in
            MainActor.assumeIsolated { action() }
            completion()
        }
        return item
    }

    private func loadArtwork(_ thumb: String?, into item: CPListItem) {
        guard let thumb, let client = library.client else { return }
        Task {
            if let image = await ArtworkCache.shared.image(thumb: thumb, size: 200, client: client) {
                item.setImage(image)
            }
        }
    }

    private func open(_ playlist: Playlist) {
        let source = PlaySource(kind: .playlist, title: playlist.title, id: playlist.id)
        pushSongs(title: playlist.title, shuffle: { [weak self] in
            guard let self else { return }
            self.showNowPlaying()
            Task { await self.player.shuffle(playlist) }
        }, load: { [library] in try await library.tracks(of: playlist, start: 0, size: 100) }, source: source)
    }

    private func open(_ album: Album) {
        let source = PlaySource(kind: .album, title: album.title, id: album.id, albumInOrder: true)
        pushSongs(title: album.title, shuffle: nil, load: { [library] in try await library.tracks(of: album) }, source: source)
    }

    private func open(_ artist: Artist) {
        let template = CPListTemplate(title: artist.title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { [weak self] in
            guard let self else { return }
            let albums = (try? await library.albums(of: artist)) ?? []
            let shuffleArtist = listItem(title: "Shuffle \(artist.title)", detail: nil, symbol: "shuffle") { [weak self] in
                guard let self else { return }
                self.showNowPlaying()
                Task {
                    guard let tracks = try? await self.library.tracks(of: artist) else { return }
                    self.player.play(tracks, source: PlaySource(kind: .artist, title: artist.title, id: artist.id), shuffled: true)
                }
            }
            let items = albums.map { album in
                let item = self.listItem(title: album.title, detail: album.year.map(String.init), symbol: "square.stack.fill") { [weak self] in
                    self?.open(album)
                }
                self.loadArtwork(album.thumb, into: item)
                return item
            }
            template.updateSections([CPListSection(items: [shuffleArtist]), CPListSection(items: items)])
        }
    }

    /// A list of songs with Shuffle on top; tapping a song plays from it.
    private func pushSongs(title: String, shuffle: (() -> Void)?, load: @escaping () async throws -> [Track], source: PlaySource) {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { [weak self] in
            guard let self else { return }
            let tracks = (try? await load()) ?? []
            let shuffleItem = listItem(title: "Shuffle", detail: nil, symbol: "shuffle") { [weak self] in
                guard let self else { return }
                if let shuffle {
                    shuffle()
                } else {
                    self.showNowPlaying()
                    self.player.play(tracks, source: PlaySource(kind: source.kind, title: source.title, id: source.id), shuffled: true)
                }
            }
            let songs = tracks.prefix(CPListTemplate.maximumItemCount - 1).enumerated().map { index, track in
                let item = CPListItem(text: track.title, detailText: track.artist)
                item.playingIndicatorLocation = .trailing
                item.isPlaying = self.player.current?.id == track.id && self.player.isPlaying
                item.handler = { [weak self] _, completion in
                    MainActor.assumeIsolated {
                        self?.showNowPlaying()
                        self?.player.play(tracks, startAt: index, source: source)
                    }
                    completion()
                }
                return item
            }
            template.updateSections([CPListSection(items: [shuffleItem]), CPListSection(items: Array(songs))])
        }
    }

    // MARK: - Now Playing

    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        template.add(self)
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Up Next"
        template.isAlbumArtistButtonEnabled = true
        updateNowPlayingButtons()
    }

    /// Back 15, the heart, repeat. Each keeps its place whether it's on or off, so nothing moves under a
    /// driver's finger.
    private func updateNowPlayingButtons() {
        let playing = player.current != nil
        let back = CPNowPlayingImageButton(image: UIImage(systemName: "gobackward.15") ?? UIImage()) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Logger.carplay.info("[carplay] back 15 from \(self.player.currentTime, format: .fixed(precision: 0))s")
                self.player.seek(to: max(0, self.player.currentTime - 15))
            }
        }
        back.isEnabled = playing

        let liked = player.current.map(library.isLiked) ?? false
        let heart = CPNowPlayingImageButton(image: UIImage(systemName: liked ? "heart.fill" : "heart") ?? UIImage()) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Logger.carplay.info("[carplay] heart")
                Task { await self.player.toggleLike() }
            }
        }
        heart.isSelected = liked
        heart.isEnabled = playing

        let mode = player.repeatMode
        let again = CPNowPlayingImageButton(image: UIImage(systemName: mode == .one ? "repeat.1" : "repeat") ?? UIImage()) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player.cycleRepeat()
                Logger.carplay.info("[carplay] repeat → \(self.player.repeatMode.rawValue, privacy: .public)")
                self.updateNowPlayingButtons()
            }
        }
        again.isSelected = mode != .off
        again.isEnabled = playing
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([back, heart, again])
    }

    func showNowPlaying() {
        guard interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { pushUpNext() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { openPlayingAlbum() }
    }

    private func openPlayingAlbum() {
        guard let track = player.current, let albumID = track.albumID else { return }
        Logger.carplay.info("[carplay] open the album that's playing")
        open(library.album(id: albumID) ?? Album(id: albumID, title: track.album, artist: track.artist, artistID: track.artistID))
    }

    private func pushUpNext() {
        let upcoming = Array(player.queue.upcoming.prefix(CPListTemplate.maximumItemCount))
        let items = upcoming.enumerated().map { offset, track in
            let item = CPListItem(text: track.title, detailText: track.artist)
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.player.jump(to: self.player.queue.index + 1 + offset)
                    self.interfaceController.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = ["Nothing up next"]
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Observation

    private func observeLibrary() {
        withObservationTracking {
            _ = library.playlists
            _ = library.recentlyAdded
            _ = library.artists
            _ = library.likedCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.observing else { return }
                self.refreshLists()
                self.observeLibrary()
            }
        }
    }

    private func observeSeason() {
        withObservationTracking {
            _ = season.theme
            _ = season.mixes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.homeTemplate?.updateGridButtons(self.homeButtons())
                self.observeSeason()
            }
        }
    }

    private func observeTrack() {
        withObservationTracking {
            _ = player.current?.id
            _ = player.repeatMode
            _ = library.likedOverrides
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.updateNowPlayingButtons()
                self.observeTrack()
            }
        }
    }
}

/// CarPlay shows at most eight grid buttons.
private let CPGridTemplateMaximumItems = 8
