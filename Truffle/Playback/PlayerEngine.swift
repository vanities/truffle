// swiftlint:disable file_length - one state machine over two decks; splitting it opens its private state to the module
import AVFoundation
import Foundation
import Observation
import os

/// Plays the queue through two AVQueuePlayers, or decks. The main deck holds the current song and, when
/// the next one follows without a crossfade, that one too, so songs run into each other without a gap.
/// In a shuffle with Crossfade on, the next song waits on the spare deck instead. Near the end of the
/// current song it starts there, the two overlap (`Crossfade` has the rules and the curves), and the
/// decks trade places: the queue, Now Playing and Plex move to the new song while the old one fades out.
@MainActor @Observable
final class PlayerEngine {
    private(set) var queue = PlayQueue()
    private(set) var source: PlaySource?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var errorMessage: String?
    /// What the current song streams as; the player shows when it's Data Saver.
    private(set) var stream: StreamMode = .original
    /// Shuffle All (or a big playlist's shuffle): the queue tops itself up as it runs low.
    private(set) var feed: ShuffleFeed?
    var isEndless: Bool { feed != nil }

    var current: Track? { queue.current }
    var duration: TimeInterval { current?.duration ?? 0 }
    var hasTrack: Bool { current != nil }

    var repeatMode: RepeatMode {
        get { queue.repeatMode }
        set {
            queue.repeatMode = newValue
            Logger.player.info("[player] repeat \(newValue.rawValue, privacy: .public)")
            preloadNext()
            save()
            notify()
        }
    }

    @ObservationIgnored var stateDidChange: (() -> Void)?

    @ObservationIgnored private let library: MusicLibrary
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkCost
    @ObservationIgnored private let reporter: PlexReporter
    /// The main deck: the current song, and the next one when it follows gaplessly.
    @ObservationIgnored private var player = AVQueuePlayer()
    /// The spare deck: empty, holding the next song for a crossfade, or fading out the last one.
    @ObservationIgnored private var spare = AVQueuePlayer()
    /// The song preloaded on the main deck and the queue position it plays.
    @ObservationIgnored private var nextItem: (item: AVPlayerItem, index: Int)?
    @ObservationIgnored private var staged: Staged?
    @ObservationIgnored private var fading: Fading?
    @ObservationIgnored private var fadeStart: (deck: AVQueuePlayer, token: Any)?
    @ObservationIgnored private var fadeTicks: (deck: AVQueuePlayer, token: Any)?
    @ObservationIgnored private var fadeWatchdog: Task<Void, Never>?
    /// The server address the current item streams from; a different one means it has to be rebuilt.
    @ObservationIgnored private var currentItemBase: URL?
    @ObservationIgnored private var pendingSeek: TimeInterval?
    /// A restored queue waits for Play before it builds an item (the server may not be reachable yet).
    @ObservationIgnored private var needsLoad = false
    @ObservationIgnored private var playWhenReady = false
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var recoveryAttempts = 0
    @ObservationIgnored private var toppingUp = false
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var itemObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var playerObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObservers: [Any] = []
    @ObservationIgnored private var enriching: Set<String> = []
    /// What each loaded item plays and how: a natural end reports its song as played, and letting it go
    /// stops its transcode on the server.
    @ObservationIgnored private var itemInfo: [ObjectIdentifier: ItemInfo] = [:]
    /// Data Saver's transcodes so far: a song whose transcode failed plays its original, and a run of
    /// failures rests them for a while.
    @ObservationIgnored private var transcodes = TranscodeHealth()
    /// One failure is often reported twice (status and notification); count it once.
    @ObservationIgnored private var failedItem: ObjectIdentifier?
    /// The current song's item. The queue player drops an item that fails, so `player.currentItem` can't
    /// say which song a failure belongs to.
    @ObservationIgnored private var playingItem: AVPlayerItem?

    private static let stateFile = "player.json"

    private struct ItemInfo {
        let track: Track
        let mode: StreamMode
        /// Where it streams from; nil for a song saved on the phone (`SongCache`).
        let endpoint: PlexEndpoint?
        /// The transcode session, for Data Saver.
        let session: String?
        /// A transcode's status, watched while it waits its turn.
        let watch: NSKeyValueObservation?
        var onPhone: Bool { endpoint == nil }
    }

    /// The next song, waiting on the spare deck to fade in over the end of `after`.
    private struct Staged {
        let item: AVPlayerItem
        let index: Int
        let track: Track
        let after: AVPlayerItem
        var plan: Crossfade.Plan
    }

    /// The last song, fading out on the spare deck while the current one fades in.
    private struct Fading {
        let item: AVPlayerItem
        let track: Track
        let start: TimeInterval
        let length: TimeInterval
        /// Its leveled volume, which the fade-out scales down from.
        let level: Float
        var loggedStep = 0
    }

    private enum FadeEnd: String {
        /// Played out under the new song.
        case completed, ended
        /// Pause, skip, seek or a new queue: the old song stops where it is.
        case cut
        /// The old song stopped moving (stalled); don't hold the new one back.
        case timeout
    }

    init(library: MusicLibrary, settings: AppSettings, network: NetworkCost? = nil) {
        self.library = library
        self.settings = settings
        self.network = network ?? NetworkCost()
        reporter = PlexReporter(library: library)
        for deck in [player, spare] {
            deck.actionAtItemEnd = .advance
            deck.automaticallyWaitsToMinimizeStalling = true
        }
        spare.volume = 0
        installObservers()
        restore()
        library.onEndpointChanged = { [weak self] endpoint in self?.endpointChanged(endpoint) }
        // A save that failed was likely aimed at an address that's gone (it left home on the public one).
        SongCache.shared.onFailure = { [weak self] in
            guard let self else { return }
            Task {
                await self.library.reconnect(reason: "song download failed")
                self.cacheAhead()
            }
        }
        library.onSignedOut = { [weak self] in
            self?.stop(clearing: true)
            SongCache.shared.removeAll()
        }
        library.onTrackUpdated = { [weak self] track in
            guard let self else { return }
            self.queue.update(track)
            self.notify()
        }
        self.network.onChange = { [weak self] metered in self?.networkCostChanged(metered) }
    }

    // MARK: - Starting things

    func play(_ tracks: [Track], startAt index: Int = 0, source: PlaySource, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        var list = tracks
        var start = index
        var source = source
        if shuffled {
            list.shuffle()
            start = 0
            source.shuffled = true
        }
        Logger.player.info("[player] play \(source.kind.rawValue, privacy: .public) \"\(source.title, privacy: .public)\" \(list.count) songs from \(start) shuffled=\(shuffled)")
        feed = nil
        self.source = source
        queue.replace(with: list, startAt: start)
        load(autoplay: true)
    }

    /// Every song in the library in a true random order, one round before any repeat.
    func shuffleAll() async {
        await startShuffle(.library, source: .shuffleAll)
    }

    /// A playlist in a true random order. Big ones are walked by position, not downloaded.
    func shuffle(_ playlist: Playlist) async {
        let source = PlaySource(kind: .playlist, title: playlist.title, id: playlist.id, shuffled: true)
        if playlist.isLarge {
            await startShuffle(.playlist(id: playlist.id, total: playlist.trackCount), source: source)
            return
        }
        isLoading = true
        notify()
        do {
            var all: [Track] = []
            while all.count < playlist.trackCount {
                let page = try await library.tracks(of: playlist, start: all.count, size: 500)
                if page.isEmpty { break }
                all += page
            }
            play(all, source: source, shuffled: true)
        } catch {
            isLoading = false
            errorMessage = "\(playlist.title) didn't load."
            notify()
        }
    }

    private func startShuffle(_ newFeed: ShuffleFeed, source newSource: PlaySource) async {
        Logger.player.info("[player] shuffle \(newSource.title, privacy: .public)")
        isLoading = true
        notify()
        do {
            let tracks = try await library.nextShuffled(5, from: newFeed)
            guard !tracks.isEmpty else {
                isLoading = false
                errorMessage = "Your library's empty. Huh."
                notify()
                return
            }
            feed = newFeed
            source = newSource
            queue.replace(with: tracks, startAt: 0)
            load(autoplay: true)
        } catch {
            isLoading = false
            errorMessage = "Shuffle hiccup. Try again?"
            Logger.player.error("[player] shuffle failed: \(error.localizedDescription, privacy: .public)")
            notify()
        }
    }

    func play(_ mix: Mix, theme: SeasonTheme) async {
        if mix.kind == .shuffleAll {
            await shuffleAll()
            return
        }
        isLoading = true
        notify()
        do {
            if let curated = library.curatedPlaylist(for: mix) {
                // A hand-picked mix plays in the order it was sequenced.
                let tracks = try await library.allTracks(of: curated)
                if !tracks.isEmpty {
                    play(tracks, source: PlaySource(kind: .playlist, title: curated.title, id: curated.id))
                    return
                }
            }
            if mix.kind == .randomAlbum, let (album, tracks) = try await library.randomAlbumTracks() {
                play(tracks, source: PlaySource(kind: .album, title: album.title, id: album.id, albumInOrder: true))
                return
            }
            let tracks = try await library.tracks(for: mix, theme: theme)
            guard !tracks.isEmpty else {
                isLoading = false
                errorMessage = "\(mix.title) came up empty."
                notify()
                return
            }
            play(tracks, source: PlaySource(kind: mix.kind == .liked ? .liked : .mix, title: mix.title, id: mix.id))
        } catch {
            isLoading = false
            errorMessage = "\(mix.title) didn't load. Try again?"
            Logger.player.error("[player] mix \(mix.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            notify()
        }
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        queue.insertNext(tracks)
        Logger.player.info("[player] play next: \(tracks.count) song(s)")
        if wasEmpty {
            source = PlaySource(kind: .songs, title: tracks.count == 1 ? tracks[0].title : "Songs")
            load(autoplay: true)
        } else {
            preloadNext()
            save()
            notify()
        }
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        Logger.player.info("[player] queued \(tracks.count) song(s)")
        if wasEmpty {
            source = PlaySource(kind: .songs, title: tracks.count == 1 ? tracks[0].title : "Songs")
            load(autoplay: true)
        } else {
            preloadNext()
            save()
            notify()
        }
    }

    func jump(to index: Int) {
        guard queue.tracks.indices.contains(index) else { return }
        leaveCurrent()
        queue.move(to: index)
        load(autoplay: true)
    }

    func removeUpcoming(at offsets: IndexSet) {
        queue.removeUpcoming(at: offsets)
        preloadNext()
        save()
        notify()
    }

    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        queue.moveUpcoming(from: offsets, to: destination)
        preloadNext()
        save()
        notify()
    }

    /// Crossfade or Data Saver changed in Settings: the next song gets readied again under the new rules.
    func playbackSettingsChanged() {
        Logger.player.info("[player] settings: crossfade \(self.settings.crossfadeSeconds)s, data saver \(self.settings.dataSaver)")
        guard player.currentItem != nil else { return }
        preloadNext()
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying || playWhenReady ? pause() : play()
    }

    func play() {
        guard queue.current != nil else { return }
        if needsLoad || player.currentItem == nil {
            load(autoplay: true, startTime: currentTime)
            return
        }
        AudioSessionManager.activate()
        playWhenReady = true
        player.play()
        Logger.player.info("[player] play")
        notify()
    }

    func pause() {
        // A pause mid-blend ends the blend: on Play, the new song carries on alone.
        endFade(.cut)
        playWhenReady = false
        player.pause()
        if let track = current { reporter.report(.paused, track: track, time: currentTime) }
        save()
        Logger.player.info("[player] pause at \(Int(self.currentTime))s")
        notify()
    }

    func next() {
        guard let index = queue.indexForNext() else {
            if isEndless {
                Logger.player.info("[player] next: topping up the shuffle first")
                Task { await topUp(thenAdvance: true) }
            }
            return
        }
        leaveCurrent()
        if let staged, staged.index == index {
            Logger.player.info("[player] next → staged \(index)")
            cutToStaged()
        } else if let preloaded = nextItem, preloaded.index == index, player.items().count > 1 {
            Logger.player.info("[player] next → preloaded \(index)")
            player.advanceToNextItem()
            if !playWhenReady { play() }
        } else {
            queue.move(to: index)
            load(autoplay: true)
        }
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let index = queue.indexForPrevious() else {
            seek(to: 0)
            return
        }
        leaveCurrent()
        queue.move(to: index)
        load(autoplay: true)
    }

    func seek(to time: TimeInterval) {
        endFade(.cut)
        let target = max(0, min(time, max(0, duration - 0.5)))
        currentTime = target
        if needsLoad || player.currentItem == nil {
            pendingSeek = target
            notify()
            return
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        Logger.player.info("[player] seek to \(Int(target))s")
        notify()
    }

    func cycleRepeat() { repeatMode = repeatMode.next }

    /// Puts what's coming up in a new random order (what's playing keeps playing).
    func shuffleUpcoming() {
        var upcoming = Array(queue.upcoming)
        guard upcoming.count > 1 else { return }
        upcoming.shuffle()
        let played = Array(queue.played)
        let current = queue.current.map { [$0] } ?? []
        let mode = queue.repeatMode
        queue.replace(with: played + current + upcoming, startAt: played.count)
        queue.repeatMode = mode
        Logger.player.info("[player] shuffled \(upcoming.count) upcoming")
        preloadNext()
        save()
        notify()
    }

    func toggleLike() async {
        guard let track = current else { return }
        do {
            try await library.setLiked(track, !library.isLiked(track))
        } catch {
            errorMessage = "The heart didn't stick."
            notify()
        }
    }

    /// Signing out, or the queue emptied.
    func stop(clearing: Bool) {
        leaveCurrent()
        dropStaged()
        player.pause()
        removeAllItems(from: player)
        nextItem = nil
        playingItem = nil
        retireLeftovers()
        playWhenReady = false
        isPlaying = false
        isLoading = false
        stream = .original
        if clearing {
            queue = PlayQueue()
            source = nil
            feed = nil
            currentTime = 0
            library.store.remove(Self.stateFile)
        }
        notify()
    }

    func clearError() { errorMessage = nil }

    // MARK: - Items

    private func load(autoplay: Bool, startTime: TimeInterval = 0) {
        guard let track = queue.current else {
            stop(clearing: false)
            return
        }
        needsLoad = false
        errorMessage = nil
        endFade(.cut, thenPrepare: false)
        dropStaged()
        removeAllItems(from: player)
        nextItem = nil
        retireLeftovers()
        guard let item = makeItem(for: track) else {
            // Not connected yet: connect, then try again.
            needsLoad = true
            isLoading = autoplay
            playWhenReady = autoplay
            notify()
            Task {
                await library.waitForAddress(reason: "play")
                if library.client != nil, needsLoad { load(autoplay: playWhenReady, startTime: startTime) }
                else if needsLoad {
                    isLoading = false
                    errorMessage = "\(library.serverName) isn't answering."
                    notify()
                }
            }
            return
        }
        currentItemBase = itemInfo[ObjectIdentifier(item)]?.endpoint?.baseURL
        player.insert(item, after: nil)
        failedItem = nil
        playingItem = item
        observe(item)
        currentTime = startTime
        pendingSeek = startTime > 1 ? startTime : nil
        stream = itemInfo[ObjectIdentifier(item)]?.mode ?? .original
        applyVolume()
        preloadNext()
        recoveryAttempts = 0
        Logger.player.info("[player] load \(self.queue.index + 1)/\(self.queue.tracks.count) \"\(track.title, privacy: .public)\" by \(track.artist, privacy: .public) [\(track.codec ?? "?", privacy: .public)\(self.stream == .dataSaver ? ", data saver \(DataSaver.kbps) kbps HLS" : "", privacy: .public)] autoplay=\(autoplay)")
        if autoplay {
            isLoading = true
            play()
        }
        enrichSoon()
        topUpIfNeeded()
        save()
        notify()
    }

    /// The original file, or with Data Saver on a metered connection, Plex's transcode (a session per song).
    private func makeItem(for track: Track) -> AVPlayerItem? {
        if let file = SongCache.shared.file(for: track) {
            // From disk: no server needed, so a cold start in the garage plays at once.
            let item = AVPlayerItem(asset: AVURLAsset(url: file))
            itemInfo[ObjectIdentifier(item)] = ItemInfo(track: track, mode: .original, endpoint: nil, session: nil, watch: nil)
            Logger.player.info("[cache] \"\(track.title, privacy: .public)\" plays from the phone")
            return item
        }
        guard let client = library.client, let partKey = track.partKey else { return nil }
        let mode = newSongMode(for: track)
        var session: String?
        let url: URL
        switch mode {
        case .original:
            url = client.streamURL(partKey: partKey)
        case .dataSaver:
            let id = UUID().uuidString.lowercased()
            session = id
            url = client.transcodeURL(ratingKey: track.id, session: id)
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 30
        let watch = mode == .dataSaver ? item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.readiedItemChanged(item) }
        } : nil
        itemInfo[ObjectIdentifier(item)] = ItemInfo(track: track, mode: mode, endpoint: client.endpoint, session: session, watch: watch)
        return item
    }

    private func newSongMode(for track: Track) -> StreamMode {
        DataSaver.mode(enabled: settings.dataSaver, metered: network.isMetered, song: track.id, health: transcodes, now: .now)
    }

    /// A transcode readied ahead (preloaded or staged) failed before its turn: its song is readied again
    /// from the original, so the queue never reaches a dead item.
    private func readiedItemChanged(_ item: AVPlayerItem) {
        guard item.status == .failed, item === nextItem?.item || item === staged?.item,
              let track = itemInfo[ObjectIdentifier(item)]?.track else { return }
        transcodeFailed(track, error: item.error)
        preloadNext()
    }

    /// The song plays its original from now on, and a run of failures rests Data Saver. The error's domain
    /// and code go to the log, never its URL.
    private func transcodeFailed(_ track: Track, error: (any Error)?) {
        let rests = transcodes.failed(track.id, at: .now)
        let nsError = error.map { $0 as NSError }
        let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
        let reason = [nsError, underlying].compactMap { $0.map { "\($0.domain) \($0.code)" } }.joined(separator: " / ")
        Logger.player.error("[datasaver] transcode failed for \"\(track.title, privacy: .public)\" (\(reason.isEmpty ? "no error" : reason, privacy: .public)); playing the original")
        if rests {
            Logger.player.error("[datasaver] \(TranscodeHealth.limit) transcodes failed in a row; originals for the next \(Int(TranscodeHealth.rest / 60)) min")
        }
    }

    /// Readies the song after the current one: on the main deck right behind it (gapless), or on the spare
    /// deck to fade in over its end (a crossfade). Nothing for Repeat One, which replays the current song.
    /// An item already readied for the same song, address and stream mode stays.
    private func preloadNext() {
        // The queue player just moved on to the preloaded song; currentItemChanged readies the one after.
        if let preloaded = nextItem, preloaded.item === player.currentItem { return }
        guard queue.repeatMode != .one, let index = queue.indexAfterEnd(), let track = queue.tracks[safe: index],
              let current = player.currentItem, let playing = queue.current else {
            dropPreloaded()
            dropStaged()
            return
        }
        switch crossfadeDecision(from: playing, item: current, to: track) {
        case .fade(let plan):
            dropPreloaded()
            if var kept = staged, kept.index == index, kept.after === current, isFresh(kept.item, for: track) {
                kept.plan = plan
                staged = kept
                armCrossfade()
                return
            }
            dropStaged()
            guard fading == nil else {
                Logger.player.debug("[crossfade] \(index + 1) waits for the last fade to finish")
                return
            }
            guard let item = makeItem(for: track) else { return }
            stage(item, index: index, track: track, after: current, plan: plan)
        case .gapless(let reason):
            dropStaged()
            if let kept = nextItem, kept.index == index, isFresh(kept.item, for: track) { return }
            dropPreloaded()
            guard let item = makeItem(for: track) else { return }
            player.insert(item, after: current)
            nextItem = (item, index)
            if reason == .off {
                Logger.player.debug("[player] preloaded \(index + 1): \(track.title, privacy: .public)")
            } else {
                Logger.player.info("[player] preloaded \(index + 1): \(track.title, privacy: .public), gapless (\(reason.rawValue, privacy: .public))")
            }
        }
    }

    private func isFresh(_ item: AVPlayerItem, for track: Track) -> Bool {
        guard item.status != .failed, let info = itemInfo[ObjectIdentifier(item)] else { return false }
        if info.onPhone { return info.track.id == track.id }
        return info.track.id == track.id && info.endpoint == library.endpoint && info.mode == newSongMode(for: track)
    }

    private func dropPreloaded() {
        guard let preloaded = nextItem else { return }
        nextItem = nil
        player.remove(preloaded.item)
        retire(preloaded.item)
    }

    /// The AVQueuePlayer moved on by itself (a song ended and the preloaded one started).
    private func currentItemChanged() {
        guard let item = player.currentItem, let preloaded = nextItem, preloaded.item === item else { return }
        // No play report here: a skip to the preloaded song lands here too (see itemEnded).
        let loaded = Set((player.items() + spare.items()).map(ObjectIdentifier.init))
        for key in Array(itemInfo.keys) where !loaded.contains(key) { retire(key) }
        queue.move(to: preloaded.index)
        nextItem = nil
        settle(on: item, how: "advanced")
        // It failed while it waited; its status observer only reports changes from here on.
        if item.status == .failed { itemFailed(item, item.error) }
    }

    /// Bookkeeping once `item`, already on the main deck, is the current song.
    private func settle(on item: AVPlayerItem, how: String) {
        failedItem = nil
        playingItem = item
        let info = itemInfo[ObjectIdentifier(item)]
        currentItemBase = info?.onPhone == true ? nil : (info?.endpoint?.baseURL ?? library.endpoint?.baseURL)
        observe(item)
        currentTime = 0
        stream = itemInfo[ObjectIdentifier(item)]?.mode ?? .original
        applyVolume()
        // Before preloading: trimming shifts the queue's positions, and the preload remembers one.
        trimHistory()
        preloadNext()
        enrichSoon()
        topUpIfNeeded()
        save()
        Logger.player.info("[player] \(how, privacy: .public) to \(self.queue.index + 1)/\(self.queue.tracks.count) \"\(self.current?.title ?? "", privacy: .public)\"\(self.stream == .dataSaver ? " (data saver)" : "", privacy: .public)")
        notify()
    }

    /// The current song ended with nothing preloaded behind it: Repeat One, a crossfade that never got to
    /// start, an endless shuffle that ran dry, or the end of the queue.
    private func itemEnded(_ item: AVPlayerItem) {
        if let fading, fading.item === item {
            endFade(.ended)
            return
        }
        // Only a song that played to its end lands here, so this is what counts as a play. An item that was
        // already let go (skipped, or a fade that just finished) has nothing left to do.
        guard let track = itemInfo[ObjectIdentifier(item)]?.track else { return }
        reporter.report(.stopped, track: track, time: track.duration)
        // With a song preloaded, the queue player has already moved on (currentItemChanged).
        guard nextItem == nil else {
            retire(item)
            return
        }
        if queue.repeatMode == .one {
            Logger.player.info("[player] repeat one")
            player.seek(to: .zero)
            player.play()
            return
        }
        retire(item)
        if staged != nil {
            Logger.player.info("[crossfade] the song ended before its fade could start; cutting over")
            cutToStaged()
            return
        }
        if let index = queue.indexAfterEnd() {
            // Nothing was readied: the next song couldn't be made, or its crossfade fell through.
            Logger.player.info("[player] nothing preloaded; loading \(index + 1)")
            queue.move(to: index)
            load(autoplay: true)
            return
        }
        if isEndless {
            Task { await topUp(thenAdvance: true) }
            return
        }
        Logger.player.info("[player] end of queue")
        playWhenReady = false
        isPlaying = false
        player.pause()
        needsLoad = true
        currentTime = 0
        save()
        notify()
    }

    private func applyVolume() {
        guard let track = current else { return }
        var gain: Float = 1
        if let fading {
            gain = Crossfade.gains(at: Crossfade.progress(at: spare.currentTime().seconds, start: fading.start, length: fading.length)).incoming
        }
        let volume = leveledVolume(for: track) * gain
        player.volume = volume
        Logger.player.debug("[player] volume \(volume, format: .fixed(precision: 2)) (loudness \(track.loudness ?? .nan, format: .fixed(precision: 1)))")
    }

    /// A song's volume from Even Out Volume, before any fade.
    private func leveledVolume(for track: Track) -> Float {
        var volume = settings.evenOutVolume ? Loudness.volume(for: track, albumMode: source?.albumInOrder == true) : 1
        #if DEBUG
        // `-TruffleMute YES`: test runs against a real library play silently.
        if UserDefaults.standard.bool(forKey: "TruffleMute") { volume = 0 }
        #endif
        return volume
    }

    private func removeAllItems(from deck: AVQueuePlayer) {
        let items = deck.items()
        deck.removeAllItems()
        for item in items { retire(item) }
    }

    /// An item that's done (ended, skipped or replaced): forget it, and end its transcode on the server.
    private func retire(_ item: AVPlayerItem) {
        retire(ObjectIdentifier(item))
    }

    private func retire(_ key: ObjectIdentifier) {
        guard let info = itemInfo.removeValue(forKey: key), let session = info.session, let endpoint = info.endpoint else { return }
        let client = PlexClient(endpoint: endpoint, identity: library.identity)
        Task {
            do {
                try await client.stopTranscode(session: session)
                Logger.player.info("[datasaver] stopped transcode \(String(session.prefix(8)), privacy: .public) for \"\(info.track.title, privacy: .public)\"")
            } catch {
                Logger.player.info("[datasaver] stopping transcode \(String(session.prefix(8)), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Items the decks already dropped on their own (a song that ended at the end of the queue).
    private func retireLeftovers() {
        for key in Array(itemInfo.keys) { retire(key) }
    }

    // MARK: - Crossfade

    private func crossfadeDecision(from track: Track, item: AVPlayerItem, to next: Track) -> Crossfade.Decision {
        Crossfade.decide(seconds: settings.crossfadeSeconds, source: source, repeatMode: queue.repeatMode,
                         from: track, length: Self.length(of: item, track: track), to: next, length: next.duration)
    }

    /// The item's own length once it's loaded (Plex's can be off by a fraction of a second), else Plex's.
    private static func length(of item: AVPlayerItem, track: Track) -> TimeInterval {
        let seconds = item.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : track.duration
    }

    private func stage(_ item: AVPlayerItem, index: Int, track: Track, after current: AVPlayerItem, plan: Crossfade.Plan) {
        removeAllItems(from: spare)
        spare.volume = 0
        spare.insert(item, after: nil)
        staged = Staged(item: item, index: index, track: track, after: current, plan: plan)
        armCrossfade()
        Logger.player.info("[crossfade] staged \(index + 1) \"\(track.title, privacy: .public)\": \(plan.length, format: .fixed(precision: 1))s from \(plan.start, format: .fixed(precision: 1))s")
    }

    private func dropStaged() {
        disarmCrossfade()
        guard let staged else { return }
        self.staged = nil
        spare.remove(staged.item)
        retire(staged.item)
    }

    /// Starts the crossfade when the current song reaches the plan's start.
    private func armCrossfade() {
        disarmCrossfade()
        guard let staged, let item = player.currentItem, staged.after === item else { return }
        let deck = player
        let time = NSValue(time: CMTime(seconds: staged.plan.start, preferredTimescale: 600))
        let token = deck.addBoundaryTimeObserver(forTimes: [time], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.crossfadeDue() }
        }
        fadeStart = (deck, token)
    }

    private func disarmCrossfade() {
        guard let fadeStart else { return }
        fadeStart.deck.removeTimeObserver(fadeStart.token)
        self.fadeStart = nil
    }

    private func crossfadeDue() {
        guard let staged, fading == nil, player.currentItem === staged.after else { return }
        beginCrossfade(at: player.currentTime().seconds)
    }

    /// The boundary only fires when playback runs across it, so a seek or a resume past it lands here.
    private func catchUpOnCrossfade(at time: TimeInterval) {
        guard let staged, fading == nil, isPlaying, player.currentItem === staged.after,
              time >= staged.plan.start + 0.5 else { return }
        Logger.player.info("[crossfade] caught up at \(time, format: .fixed(precision: 1))s")
        beginCrossfade(at: time)
    }

    /// The staged song starts on the spare deck at silence, the decks trade places, and the fade ticks
    /// bring one up as the other goes down.
    private func beginCrossfade(at time: TimeInterval) {
        guard let staged, fading == nil, let outgoingItem = player.currentItem, let outgoing = queue.current else { return }
        disarmCrossfade()
        guard staged.item.status != .failed else {
            Logger.player.error("[crossfade] \"\(staged.track.title, privacy: .public)\" didn't load; it starts fresh when this song ends")
            dropStaged()
            return
        }
        let length = min(staged.plan.length, Self.length(of: outgoingItem, track: outgoing) - time)
        // Too close to the end to blend: it cuts over when this song ends (itemEnded).
        guard length >= Crossfade.minimumLength else { return }
        self.staged = nil
        let outgoingDeck = player
        player = spare
        spare = outgoingDeck
        fading = Fading(item: outgoingItem, track: outgoing, start: time, length: length, level: leveledVolume(for: outgoing))
        Logger.player.info("[crossfade] start \"\(outgoing.title, privacy: .public)\" → \"\(staged.track.title, privacy: .public)\" over \(length, format: .fixed(precision: 1))s at \(time, format: .fixed(precision: 1))s")
        player.volume = 0
        player.play()
        startFadeTicks(length: length)
        queue.move(to: staged.index)
        settle(on: staged.item, how: "crossfading")
    }

    private func startFadeTicks(length: TimeInterval) {
        stopFadeTicks()
        let deck = spare
        let token = deck.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.fadeTick(CMTimeGetSeconds(time)) }
        }
        fadeTicks = (deck, token)
        fadeWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 5))
            guard !Task.isCancelled else { return }
            self?.endFade(.timeout)
        }
    }

    private func stopFadeTicks() {
        if let fadeTicks { fadeTicks.deck.removeTimeObserver(fadeTicks.token) }
        fadeTicks = nil
        fadeWatchdog?.cancel()
        fadeWatchdog = nil
    }

    /// Driven by the outgoing song's own clock, so the curve stays put if it stalls.
    private func fadeTick(_ time: TimeInterval) {
        guard var fading, time.isFinite else { return }
        let progress = Crossfade.progress(at: time, start: fading.start, length: fading.length)
        let gains = Crossfade.gains(at: progress)
        spare.volume = fading.level * gains.outgoing
        player.volume = (current.map(leveledVolume(for:)) ?? 1) * gains.incoming
        let step = Int(progress * 4)
        if step > fading.loggedStep {
            fading.loggedStep = step
            self.fading = fading
            Logger.player.info("[crossfade] \(step * 25)%: out \(gains.outgoing, format: .fixed(precision: 2)) in \(gains.incoming, format: .fixed(precision: 2))")
        }
        if progress >= 1 { endFade(.completed) }
    }

    /// The old song stops and goes to Plex as played (it ran out under the new one) or as far as it got
    /// (cut short). The new song plays on at its own level, and the spare deck is free for the next blend.
    private func endFade(_ how: FadeEnd, thenPrepare: Bool = true) {
        guard let fading else { return }
        self.fading = nil
        stopFadeTicks()
        let reached = spare.currentTime().seconds
        let playedThrough = how == .completed || how == .ended
        let reportedTime = playedThrough ? fading.track.duration : (reached.isFinite ? reached : fading.start)
        reporter.report(.stopped, track: fading.track, time: reportedTime)
        spare.pause()
        removeAllItems(from: spare)
        spare.volume = 0
        retire(fading.item)
        applyVolume()
        Logger.player.info("[crossfade] done \"\(fading.track.title, privacy: .public)\" (\(how.rawValue, privacy: .public)), reported at \(Int(reportedTime))s")
        if thenPrepare, nextItem == nil, staged == nil { preloadNext() }
    }

    /// The staged song takes over at once at its own level: Next before the blend, or the song ended before
    /// it could start. It's buffered on the spare deck already, so there's no gap.
    private func cutToStaged() {
        guard let staged else { return }
        disarmCrossfade()
        self.staged = nil
        guard staged.item.status != .failed else {
            spare.remove(staged.item)
            retire(staged.item)
            queue.move(to: staged.index)
            load(autoplay: true)
            return
        }
        let finished = player
        player = spare
        spare = finished
        removeAllItems(from: spare)
        nextItem = nil
        queue.move(to: staged.index)
        settle(on: staged.item, how: "cut")
        play()
    }

    /// Before the queue moves somewhere new: a blend in progress ends (the old song goes to Plex first),
    /// then the current song is reported stopped where it is.
    private func leaveCurrent() {
        endFade(.cut, thenPrepare: false)
        guard let track = current, player.currentItem != nil else { return }
        reporter.report(.stopped, track: track, time: currentTime)
    }

    // MARK: - Shuffle top-up, details

    private func topUpIfNeeded() {
        guard isEndless, queue.upcoming.count < 3, !toppingUp else { return }
        Task { await topUp(thenAdvance: false) }
    }

    private func topUp(thenAdvance: Bool) async {
        guard !toppingUp else { return }
        toppingUp = true
        defer { toppingUp = false }
        guard let feed else { return }
        do {
            let more = try await library.nextShuffled(5, from: feed)
            queue.append(more)
            Logger.player.info("[player] shuffle topped up +\(more.count), \(self.queue.upcoming.count) upcoming")
            if thenAdvance, let index = queue.indexForNext() {
                queue.move(to: index)
                load(autoplay: true)
            } else {
                preloadNext()
                save()
                notify()
            }
        } catch {
            Logger.player.error("[player] shuffle top-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimHistory() {
        guard isEndless else { return }
        queue.trimPlayed(keeping: 50)
    }

    /// Loudness comes only with each song's full details; fetch them for the next few songs.
    private func enrichSoon() {
        let window = [queue.current].compactMap { $0 } + Array(queue.upcoming.prefix(4))
        let missing = window.filter { !$0.hasLoudness && !enriching.contains($0.id) }.map(\.id)
        guard !missing.isEmpty else { return }
        enriching.formUnion(missing)
        Task {
            defer { enriching.subtract(missing) }
            do {
                let detailed = try await library.details(for: MixBuilder.distinct(missing))
                for track in detailed {
                    let merged = queue.tracks.first { $0.id == track.id }.map { $0.merging(details: track) } ?? track
                    queue.update(merged)
                }
                if detailed.contains(where: { $0.id == current?.id }) { applyVolume() }
                Logger.player.debug("[player] details for \(detailed.count) song(s)")
            } catch {
                Logger.player.info("[player] details failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Connection changes and failures

    /// A new address (left home Wi-Fi): the preloaded song moves to it now; the current one keeps
    /// playing from its buffer and moves over if it stalls or fails.
    private func endpointChanged(_ endpoint: PlexEndpoint) {
        Logger.player.info("[player] server address now \(endpoint.kind.rawValue, privacy: .public)")
        cacheAhead()
        guard player.currentItem != nil else { return }
        preloadNext()
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate, let base = currentItemBase, base != endpoint.baseURL {
            rebuildCurrent(reason: "stalled on the old address")
        }
    }

    /// On or off cellular: with Data Saver on, the next song is readied again in the other mode. The one
    /// playing finishes the way it started.
    private func networkCostChanged(_ metered: Bool) {
        guard settings.dataSaver, player.currentItem != nil else { return }
        Logger.player.info("[datasaver] \(metered ? "on cellular: the next song streams the transcode" : "off cellular: the next song streams the original", privacy: .public)")
        preloadNext()
    }

    private func rebuildCurrent(reason: String) {
        let resume = playWhenReady
        Logger.player.info("[player] rebuilding current item at \(Int(self.currentTime))s: \(reason, privacy: .public)")
        load(autoplay: resume, startTime: currentTime)
    }

    private func itemFailed(_ item: AVPlayerItem, _ error: (any Error)?) {
        if let fading, fading.item === item {
            Logger.player.error("[crossfade] \"\(fading.track.title, privacy: .public)\" failed while fading out: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
            endFade(.cut)
            return
        }
        guard item === playingItem, failedItem != ObjectIdentifier(item) else { return }
        failedItem = ObjectIdentifier(item)
        if let info = itemInfo[ObjectIdentifier(item)], info.onPhone {
            // A saved file that won't play goes, and the song streams from the same spot.
            Logger.player.error("[cache] saved \"\(info.track.title, privacy: .public)\" failed: \(error?.localizedDescription ?? "unknown error", privacy: .public); streaming it")
            SongCache.shared.remove(info.track)
            load(autoplay: playWhenReady, startTime: currentTime)
            return
        }
        if let info = itemInfo[ObjectIdentifier(item)], DataSaver.onFailure(of: info.mode) == .playOriginal {
            // Data Saver never costs a song: the original takes over from the same spot.
            transcodeFailed(info.track, error: error ?? item.error)
            load(autoplay: playWhenReady, startTime: currentTime)
            return
        }
        let message = error?.localizedDescription ?? "unknown error"
        Logger.player.error("[player] item failed (attempt \(self.recoveryAttempts + 1)): \(message, privacy: .public)")
        recoveryAttempts += 1
        guard recoveryAttempts <= 2 else {
            errorMessage = "\(current?.title ?? "That song") wouldn't play. Skipped it."
            recoveryAttempts = 0
            if queue.indexForNext() != nil { next() } else { stop(clearing: false) }
            return
        }
        let resumeAt = currentTime
        let wasPlaying = playWhenReady
        Task {
            // Same address as the item that failed: check the server is still reachable there.
            if library.endpoint?.baseURL == currentItemBase {
                await library.reconnect(reason: "playback failed")
            }
            load(autoplay: wasPlaying, startTime: resumeAt)
        }
    }

    // MARK: - Observers

    private func installObservers() {
        // Both decks report; only the main deck's clock, status and current item steer the engine.
        for deck in [player, spare] {
            let id = ObjectIdentifier(deck)
            timeObservers.append(deck.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, ObjectIdentifier(self.player) == id else { return }
                    self.tick(CMTimeGetSeconds(time))
                }
            })
            playerObservers.append(deck.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.syncPlayingState() }
            })
            playerObservers.append(deck.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.currentItemChanged() }
            })
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { self?.itemEnded(item) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
            MainActor.assumeIsolated { self?.itemFailed(item, error) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                // A fading song that stalls just stops moving its fade; the watchdog ends it.
                guard let self, item == nil || item === self.player.currentItem else { return }
                Logger.player.info("[player] stalled")
                if let endpoint = self.library.endpoint, let base = self.currentItemBase, endpoint.baseURL != base {
                    self.rebuildCurrent(reason: "stalled, server address changed")
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                if reason == .newDeviceAvailable,
                   AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .carAudio }) {
                    CarLog.shared.note("Audio went to the car")
                }
                // Headphones out, or the car disconnected: stop, like every music app.
                guard reason == .oldDeviceUnavailable, let self, self.playWhenReady else { return }
                Logger.player.info("[player] audio route lost, pausing")
                self.pause()
            }
        })
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservers = [item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(item) }
        }]
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === playingItem else { return }
        switch item.status {
        case .readyToPlay:
            if let seek = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                Logger.player.info("[player] resumed at \(Int(seek))s")
            }
            // Its own length is known now: plan the crossfade again from it.
            if staged != nil { preloadNext() }
        case .failed:
            itemFailed(item, item.error)
        default:
            break
        }
    }

    private func tick(_ seconds: TimeInterval) {
        guard player.currentItem != nil, seconds.isFinite, pendingSeek == nil else { return }
        currentTime = seconds
        ticks += 1
        if isPlaying, let track = current {
            // While the last song fades out, its "stopped" goes to Plex first, as between gapless songs.
            if fading == nil { reporter.report(.playing, track: track, time: seconds) }
            if ticks % 20 == 0 { save() }
        }
        catchUpOnCrossfade(at: seconds)
        if ticks % 10 == 0 { stateDidChange?() }
    }

    private func syncPlayingState() {
        let status = player.timeControlStatus
        let playing = status == .playing
        let loading = status == .waitingToPlayAtSpecifiedRate
        guard playing != isPlaying || loading != isLoading else { return }
        isPlaying = playing
        isLoading = loading && playWhenReady
        if playing {
            recoveryAttempts = 0
            CarLog.shared.soundStarted(fromPhone: playingItem.flatMap { itemInfo[ObjectIdentifier($0)] }?.onPhone ?? false)
            if stream == .dataSaver { transcodes.played() }
            if fading == nil, let track = current { reporter.report(.playing, track: track, time: currentTime) }
        }
        Logger.player.debug("[player] status playing=\(playing) loading=\(loading)")
        notify()
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            Logger.player.info("[player] interruption began (playing=\(self.playWhenReady))")
            wasPlayingBeforeInterruption = playWhenReady
            pause()
        case .ended:
            Logger.player.info("[player] interruption ended shouldResume=\(options.contains(.shouldResume))")
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) { play() }
            wasPlayingBeforeInterruption = false
        default:
            break
        }
    }

    private func notify() {
        stateDidChange?()
    }

    // MARK: - Saving

    func save() {
        guard !queue.isEmpty else { return }
        var saved = queue
        // A long shuffle session needn't save hundreds of songs already played.
        saved.trimPlayed(keeping: 50)
        library.store.save(PlayerState(queue: saved, time: currentTime, source: source, feed: feed, savedAt: .now),
                           to: Self.stateFile)
        cacheAhead()
    }

    /// The song playing (or paused) and the next few, saved to the phone on Wi-Fi. Saving runs on every
    /// queue change and every few seconds of play; SongCache skips what's saved or on its way.
    private func cacheAhead() {
        guard !library.isDemo, let client = library.client, let current = queue.current else { return }
        SongCache.shared.want([current] + queue.upcoming.prefix(SongCache.ahead), client: client)
    }

    /// For the car log: what a start that never made a sound was stuck on.
    var startState: String {
        let song = current.map { SongCache.shared.contains($0) ? "song saved on the phone" : "song not saved" } ?? "no queue"
        let connection = library.client == nil ? "no server address" : "server address found"
        return "\(isLoading ? "loading" : isPlaying ? "playing" : "stopped"), \(song), \(connection)\(errorMessage.map { ", error: \($0)" } ?? "")"
    }

    private func restore() {
        guard let state = library.store.load(PlayerState.self, from: Self.stateFile), !state.queue.isEmpty else { return }
        queue = state.queue
        source = state.source
        feed = state.feed
        currentTime = state.time
        pendingSeek = state.time > 1 ? state.time : nil
        needsLoad = true
        Logger.player.info("[player] restored \(state.queue.tracks.count) songs at \(state.queue.index + 1), \(Int(state.time))s into \"\(state.queue.current?.title ?? "", privacy: .public)\"")
    }
}
