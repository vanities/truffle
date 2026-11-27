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
    /// The lighter stream is on because the original couldn't keep up, not because Data Saver asked.
    private(set) var lighterForSignal = false
    /// How much of the current song is in hand, 0 to 1: all of it when it plays from the phone, otherwise
    /// how far its stream has buffered. The player draws it under the scrubber.
    private(set) var bufferedFraction: Double = 0
    /// The current song plays from a file saved on the phone (`SongCache`), not a stream.
    private(set) var playsFromPhone = false
    /// Goes up each time a song lands on the phone, so rows that mark saved songs look again.
    private(set) var savedRevision = 0
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
    /// Where the song should start once an address is found; a skip while waiting moves it (to 0).
    @ObservationIgnored private var addressWait: (task: Task<Void, Never>, startTime: TimeInterval)?
    @ObservationIgnored private var cacheAheadDelay: Task<Void, Never>?
    @ObservationIgnored private var playWhenReady = false
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var recoveryAttempts = 0
    /// Runs while the current song waits to play: starts it early or reconnects (`Buffering`).
    @ObservationIgnored private var bufferWatch: (item: ObjectIdentifier, task: Task<Void, Never>)?
    /// How often the current song was started early (each start asks for more in hand), and how often it
    /// was reconnected for going quiet.
    @ObservationIgnored private var bufferTries: (song: String, starts: Int, reconnects: Int)?
    /// Set when an original couldn't keep up: new songs stream the lighter copy for a while.
    @ObservationIgnored private var weakSignal = WeakSignal()
    /// No sound though it should be playing; the car log gets a line when it ends (`Silence`).
    @ObservationIgnored private var silence: (began: ContinuousClock.Instant, record: Silence, stream: Silence.Stream.Kind, watch: Task<Void, Never>)?
    /// The item that last made a sound, to tell a song that stopped mid-way from one that hasn't started.
    @ObservationIgnored private var lastSounding: ObjectIdentifier?
    /// Whether songs may save right now (`playerHasWhatItNeeds`), to act only when it changes.
    @ObservationIgnored private var savingIsFree = true
    /// Readies the next song again after it failed while waiting (`readiedItemChanged`).
    @ObservationIgnored private var readyAgain: Task<Void, Never>?
    private static let readyAgainAfter: TimeInterval = 8
    @ObservationIgnored private var toppingUp = false
    /// Next, or the end of a song, reached the last song queued in an endless shuffle: the top-up moves on
    /// to its first song when it lands. Any other load (a jump, a new queue) takes that over.
    @ObservationIgnored private var advanceAfterTopUp = false
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
    /// An endless shuffle keeps at least this many songs coming, and asks for `topUpCount` more below it:
    /// room for a run of skips while the top-up is on its way, and for `SongCache.ahead`.
    static let runway = 5
    static let topUpCount = 5

    private struct ItemInfo {
        let track: Track
        let mode: StreamMode
        /// Where it streams from; nil for a song saved on the phone (`SongCache`).
        let endpoint: PlexEndpoint?
        /// The transcode session, for Data Saver.
        let session: String?
        /// A stream's status, watched while it waits its turn behind the song playing.
        let watch: NSKeyValueObservation?
        /// The lighter stream, chosen for a weak signal rather than by Data Saver.
        var forSignal = false
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
        // A song saved while its stream sat readied behind the one playing: play the file instead.
        SongCache.shared.onSaved = { [weak self] in
            self?.savedRevision += 1
            self?.preloadNext()
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
            let tracks = try await library.nextShuffled(Self.topUpCount, from: newFeed)
            guard !tracks.isEmpty else {
                isLoading = false
                errorMessage = "Your library's empty. Huh."
                notify()
                return
            }
            feed = newFeed
            source = newSource
            queue.replace(with: tracks, startAt: 0)
            dropRepeatAllIfEndless()
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
        Logger.player.info("[player] settings: crossfade \(self.settings.crossfadeSeconds)s, data saver \(self.settings.dataSaver), save ahead on cellular \(self.settings.saveOnCellular)")
        cacheAhead()
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
        endSilence(.paused)
        playWhenReady = false
        player.pause()
        if let track = current { reporter.report(.paused, track: track, time: currentTime) }
        save()
        Logger.player.info("[player] pause at \(Int(self.currentTime))s")
        notify()
    }

    func next() {
        guard let index = queue.indexForNext(endless: isEndless) else {
            if isEndless {
                playWhenReady = true
                advanceWhenToppedUp(reason: "next")
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
        guard let index = queue.indexForPrevious(endless: isEndless) else {
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

    func cycleRepeat() { repeatMode = repeatMode.next(endless: isEndless) }

    /// Repeat All left on from an album can't carry into an endless shuffle: there's nothing to go round, and
    /// the button would be lit for nothing.
    private func dropRepeatAllIfEndless() {
        guard isEndless, queue.repeatMode == .all else { return }
        queue.repeatMode = .off
        Logger.player.info("[player] repeat all → off: an endless shuffle has no end to repeat from")
    }

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
        silence?.watch.cancel()
        silence = nil
        playWhenReady = false
        updateSaving()
        isPlaying = false
        isLoading = false
        stream = .original
        lighterForSignal = false
        refreshBuffered()
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
        advanceAfterTopUp = false
        errorMessage = nil
        endFade(.cut, thenPrepare: false)
        dropStaged()
        removeAllItems(from: player)
        nextItem = nil
        retireLeftovers()
        guard let item = makeItem(for: track) else {
            // Not connected yet: connect, then load whatever is current by then. Skips while waiting only move
            // the queue (and the start time); one wait serves them all.
            needsLoad = true
            isLoading = autoplay
            playWhenReady = autoplay
            notify()
            if let addressWait {
                self.addressWait = (addressWait.task, startTime)
                return
            }
            let task = Task {
                await library.waitForAddress(reason: "play")
                let start = addressWait?.startTime ?? startTime
                addressWait = nil
                if library.client != nil, needsLoad { load(autoplay: playWhenReady, startTime: start) }
                else if needsLoad {
                    isLoading = false
                    errorMessage = "\(library.serverName) isn't answering."
                    notify()
                }
            }
            addressWait = (task, startTime)
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
        lighterForSignal = itemInfo[ObjectIdentifier(item)]?.forSignal ?? false
        refreshBuffered()
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
        watchBuffer()
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
        let watch = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.readiedItemChanged(item) }
        }
        itemInfo[ObjectIdentifier(item)] = ItemInfo(track: track, mode: mode, endpoint: client.endpoint, session: session, watch: watch,
                                                    forSignal: mode == .dataSaver && !(settings.dataSaver && network.isMetered))
        return item
    }

    private func newSongMode(for track: Track) -> StreamMode {
        DataSaver.mode(enabled: settings.dataSaver, metered: network.isMetered, weakSignal: weakSignal.isWeak(at: .now),
                       song: track.id, health: transcodes, now: .now)
    }

    /// A song readied ahead (preloaded or staged) failed before its turn, so the queue never reaches a dead
    /// item. A transcode is readied again from the original. An original failed because nothing answered (a
    /// dead zone outlasting its request): it's readied again every few seconds until something does.
    ///
    /// DO NOT leave a failed item readied: the queue player drops it when the song playing ends, moves on to
    /// nothing, and the music stops for good, signal or no signal (`scripts/road_test.py "0:lte 150:dead
    /// 570:lte 600:end" --save-ahead NO`, 2026-11-26: silent from the end of song 3 on, 30 s past the dead zone).
    private func readiedItemChanged(_ item: AVPlayerItem) {
        guard item.status == .failed, item === nextItem?.item || item === staged?.item,
              let info = itemInfo[ObjectIdentifier(item)] else { return }
        if info.mode == .dataSaver {
            transcodeFailed(info.track, error: item.error)
            preloadNext()
            return
        }
        let nsError = item.error.map { $0 as NSError }
        Logger.player.error("[player] \"\(info.track.title, privacy: .public)\", readied next, failed before its turn (\(nsError?.domain ?? "no error", privacy: .public) \(nsError?.code ?? 0)); readying it again in \(Int(Self.readyAgainAfter)) s")
        readyAgain?.cancel()
        readyAgain = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readyAgainAfter))
            guard !Task.isCancelled, let self else { return }
            self.preloadNext()
        }
    }

    /// The song playing ended and the one readied behind it should have taken over (`currentItemChanged`). If
    /// it failed while it waited, the queue player dropped it instead: load it now, and the usual waiting
    /// (the buffer watch, finding the server again) carries on until it plays.
    private func moveOnIfStranded(after ended: ObjectIdentifier) {
        guard playWhenReady, playingItem.map(ObjectIdentifier.init) == ended,
              let index = nextItem?.index ?? queue.indexAfterEnd(endless: isEndless) else { return }
        Logger.player.error("[player] the song readied next never took over; loading \(index + 1) now")
        silence?.record.moment = .songStart
        silence?.record.did("the next song had failed while it waited")
        dropPreloaded()
        queue.move(to: index)
        load(autoplay: true)
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
        guard queue.repeatMode != .one, let index = queue.indexAfterEnd(endless: isEndless), let track = queue.tracks[safe: index],
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
        // Saved since it was readied as a stream: the file needs no signal. Not in the current song's last
        // seconds, where swapping what comes next could open a gap.
        if info.track.id == track.id, duration - currentTime > 15, SongCache.shared.contains(track) { return false }
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
        // A silence that began as the last song ran out is this song not starting.
        silence?.record.moment = .songStart
        let info = itemInfo[ObjectIdentifier(item)]
        currentItemBase = info?.onPhone == true ? nil : (info?.endpoint?.baseURL ?? library.endpoint?.baseURL)
        observe(item)
        currentTime = 0
        // A resume position still waiting on the last song (skipped before it was ready) isn't this song's:
        // left set, it stopped the clock here, or started this song partway in.
        pendingSeek = nil
        stream = itemInfo[ObjectIdentifier(item)]?.mode ?? .original
        lighterForSignal = itemInfo[ObjectIdentifier(item)]?.forSignal ?? false
        refreshBuffered()
        applyVolume()
        // Before preloading: trimming shifts the queue's positions, and the preload remembers one.
        trimHistory()
        preloadNext()
        enrichSoon()
        topUpIfNeeded()
        save()
        watchBuffer()
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
        // With a song preloaded, the queue player moves on by itself (currentItemChanged), unless that song
        // failed while it waited.
        guard nextItem == nil else {
            retire(item)
            let ended = ObjectIdentifier(item)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.moveOnIfStranded(after: ended)
            }
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
        if let index = queue.indexAfterEnd(endless: isEndless) {
            // Nothing was readied: the next song couldn't be made, or its crossfade fell through.
            Logger.player.info("[player] nothing preloaded; loading \(index + 1)")
            queue.move(to: index)
            load(autoplay: true)
            return
        }
        if isEndless {
            advanceWhenToppedUp(reason: "the last song queued ended")
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
        guard isEndless, queue.upcoming.count < Self.runway, !toppingUp else { return }
        Task { await topUp() }
    }

    /// The shuffle has nothing queued past this song yet. The top-up (one already on its way, or a new one)
    /// plays its first song when it lands; until then the song playing keeps playing.
    private func advanceWhenToppedUp(reason: String) {
        Logger.player.info("[player] \(reason, privacy: .public): nothing queued past this song, moving on when the shuffle tops up")
        advanceAfterTopUp = true
        silence?.record.did("waited for more shuffle songs")
        isLoading = playWhenReady
        notify()
        Task { await topUp() }
    }

    /// More songs for an endless shuffle. A fetch that fails is asked again while something waits on it
    /// (`advanceAfterTopUp`); otherwise the next song's turn asks. Songs that arrive after another queue took
    /// over are dropped, so a shuffle's songs never land in an album.
    private func topUp() async {
        guard !toppingUp, let feed else { return }
        toppingUp = true
        defer { toppingUp = false }
        let sw = Stopwatch()
        var wait: Duration = .seconds(2)
        for attempt in 1...6 {
            do {
                let more = try await library.nextShuffled(Self.topUpCount, from: feed)
                guard self.feed == feed else {
                    Logger.player.info("[player] shuffle top-up arrived after another queue started; dropped")
                    return
                }
                queue.append(more)
                Logger.player.info("[player] shuffle topped up +\(more.count), \(self.queue.upcoming.count) upcoming in \(sw.ms, format: .fixed(precision: 0))ms")
                if advanceAfterTopUp, let index = queue.indexForNext(endless: true) {
                    leaveCurrent()
                    queue.move(to: index)
                    load(autoplay: playWhenReady)
                    return
                }
                if !more.isEmpty || !advanceAfterTopUp {
                    preloadNext()
                    save()
                    notify()
                    return
                }
            } catch {
                Logger.player.error("[player] shuffle top-up failed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
            }
            guard advanceAfterTopUp, self.feed == feed else { return }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, .seconds(20))
            guard advanceAfterTopUp, self.feed == feed else { return }
        }
        guard advanceAfterTopUp else { return }
        Logger.player.error("[player] shuffle top-up gave up after \(sw.seconds, format: .fixed(precision: 0))s; Play asks again")
        advanceAfterTopUp = false
        playWhenReady = isPlaying
        isLoading = false
        errorMessage = "The shuffle couldn't reach \(library.serverName) for more songs."
        notify()
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
        // A different way to the server: whatever was slow may not be.
        weakSignal.clear()
        cacheAhead()
        // A top-up that failed while there was no address gets its turn now, not at the next song.
        topUpIfNeeded()
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
            silence?.record.did("the saved file wouldn't play")
            load(autoplay: playWhenReady, startTime: currentTime)
            return
        }
        if let info = itemInfo[ObjectIdentifier(item)], DataSaver.onFailure(of: info.mode) == .playOriginal {
            // Data Saver never costs a song: the original takes over from the same spot.
            transcodeFailed(info.track, error: error ?? item.error)
            silence?.record.did("the lighter stream failed")
            load(autoplay: playWhenReady, startTime: currentTime)
            return
        }
        let message = error?.localizedDescription ?? "unknown error"
        Logger.player.error("[player] item failed (attempt \(self.recoveryAttempts + 1)): \(message, privacy: .public)")
        recoveryAttempts += 1
        silence?.record.did("the stream failed")
        guard recoveryAttempts <= 2 else {
            errorMessage = "\(current?.title ?? "That song") wouldn't play. Skipped it."
            recoveryAttempts = 0
            if queue.indexForNext(endless: isEndless) != nil || isEndless { next() } else { stop(clearing: false) }
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
                CarLog.shared.note("The speaker it was playing through went away; paused")
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
        refreshBuffered()
        updateSaving()
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
        watchBuffer()
        noteSilence(playing: playing)
        guard playing != isPlaying || ((loading || advanceAfterTopUp) && playWhenReady) != isLoading else { return }
        isPlaying = playing
        isLoading = (loading || advanceAfterTopUp) && playWhenReady
        if playing {
            recoveryAttempts = 0
            CarLog.shared.soundStarted(fromPhone: playingItem.flatMap { itemInfo[ObjectIdentifier($0)] }?.onPhone ?? false)
            if stream == .dataSaver { transcodes.played() }
            if fading == nil, let track = current { reporter.report(.playing, track: track, time: currentTime) }
        }
        Logger.player.debug("[player] status playing=\(playing) loading=\(loading)\(loading ? " (\(self.player.reasonForWaitingToPlay?.rawValue ?? "no reason"))" : "", privacy: .public)")
        notify()
    }

    // MARK: - Silences

    private func noteSilence(playing: Bool) {
        if playing {
            lastSounding = player.currentItem.map(ObjectIdentifier.init)
            endSilence(.sound)
        } else if playWhenReady, silence == nil, queue.current != nil {
            let item = player.currentItem.map(ObjectIdentifier.init)
            let record = Silence(moment: item != nil && item == lastSounding ? .midSong(at: currentTime) : .songStart)
            let watch = Task { [weak self] in
                try? await Task.sleep(for: Silence.longWait)
                guard !Task.isCancelled, let self, let silence = self.silence else { return }
                // Stopped without a pause (the queue ran out): nothing was waiting to play.
                guard self.playWhenReady, !self.isPlaying else {
                    self.silence = nil
                    return
                }
                self.writeSilence(silence.record, began: silence.began, stream: silence.stream, ending: .stillWaiting)
            }
            silence = (.now, record, streamKind, watch)
            // A stream that ran dry gets the whole connection back from the songs saving behind it.
            updateSaving()
        }
    }

    private func endSilence(_ ending: Silence.Ending) {
        guard let silence else { return }
        self.silence = nil
        silence.watch.cancel()
        updateSaving()
        writeSilence(silence.record, began: silence.began, stream: silence.stream, ending: ending)
    }

    /// What the current song is coming from.
    private var streamKind: Silence.Stream.Kind {
        guard let info = playingItem.flatMap({ itemInfo[ObjectIdentifier($0)] }) else { return .nothingLoaded }
        return info.onPhone ? .onPhone : info.mode == .dataSaver ? .lighter : .original
    }

    /// `stream` is what the song was coming from when the sound stopped; the steps say what changed after.
    private func writeSilence(_ record: Silence, began: ContinuousClock.Instant, stream: Silence.Stream.Kind, ending: Silence.Ending) {
        let elapsed = ContinuousClock.now - began
        let lasted = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        // A start the car log is already timing gets that line ("Sound 41.2 s after the car screen opened").
        guard record.isWorthNoting(lasted: lasted), !(record.moment == .songStart && CarLog.shared.isExpectingSound) else { return }
        // Nothing was loaded when it began (a start waiting on an address): say what it turned out to be.
        let kind = stream == .nothingLoaded ? streamKind : stream
        let ahead = queue.upcoming.prefix(SongCache.ahead)
        CarLog.shared.note(record.line(lasted: lasted, ending: ending, song: queue.index + 1, of: queue.tracks.count,
                                       stream: Silence.Stream(kind: kind, cellular: network.isMetered),
                                       savedAhead: ahead.filter(SongCache.shared.contains).count, ofNext: ahead.count))
    }

    // MARK: - Buffering

    /// While the current song waits to play, twice a second: start it once it's keeping up, move it to the
    /// lighter stream when its original never will, or reconnect when nothing arrives (`Buffering` has the
    /// rules). Songs on the phone never wait long enough to matter.
    private func watchBuffer() {
        guard playWhenReady, player.timeControlStatus == .waitingToPlayAtSpecifiedRate, let item = playingItem,
              let info = itemInfo[ObjectIdentifier(item)], !info.onPhone else {
            bufferWatch?.task.cancel()
            bufferWatch = nil
            return
        }
        let id = ObjectIdentifier(item)
        guard bufferWatch?.item != id else { return }
        bufferWatch?.task.cancel()
        if bufferTries?.song != info.track.id { bufferTries = (info.track.id, 0, 0) }
        let track = info.track
        let mode = info.mode
        let task = Task { [weak self] in
            let sw = Stopwatch()
            var ends: [(at: TimeInterval, end: TimeInterval)] = []
            var lastGain = 0.0
            var arrivingSince = 0.0
            var lastBytes: Int64 = 0
            var lastLogged = -5.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.playingItem === item, self.playWhenReady,
                      self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { break }
                let now = sw.seconds
                // Not where it will play from yet (a resume waiting on its seek): what's buffered is elsewhere.
                guard self.pendingSeek == nil else {
                    ends = []
                    lastGain = now
                    continue
                }
                let buffered = Self.buffered(item)
                self.refreshBuffered()
                // Bytes count as arriving too: an MP4 with its index at the end reports nothing buffered
                // until AVPlayer decides to start, while the file comes in.
                let bytes = item.accessLog()?.events.last?.numberOfBytesTransferred ?? 0
                if (ends.last.map { buffered.end > $0.end + 0.01 } ?? false) || bytes > lastBytes {
                    // The first of it after a gap: the rate starts over from here. Measured across the gap, a
                    // song whose connection had just come back read as arriving at 0.1 times its speed, and
                    // went to the lighter stream for five minutes on a good signal.
                    if now - lastGain > 1.5 {
                        ends = []
                        arrivingSince = now
                    }
                    lastGain = now
                }
                lastBytes = bytes
                ends.append((now, buffered.end))
                ends.removeAll { now - $0.at > 4 }
                let length = Self.length(of: item, track: track)
                let sample = Buffering.Sample(waited: now, ahead: buffered.ahead, fill: Buffering.fill(ends), idle: now - lastGain,
                                              arriving: now - arrivingSince, complete: length > 0 && buffered.end >= length - 1)
                let tries = self.bufferTries ?? (track.id, 0, 0)
                let canLighten = mode == .original && buffered.end > 0
                    && DataSaver.mode(enabled: true, metered: true, song: track.id, health: self.transcodes, now: .now) == .dataSaver
                var verdict = Buffering.verdict(for: sample, earlyStarts: tries.starts, canLighten: canLighten)
                if verdict == .reconnect, tries.reconnects >= Buffering.reconnects { verdict = .wait }
                #if DEBUG
                // `-TruffleBufferHands off`: watch and log, but leave every wait to AVPlayer, to measure against.
                if UserDefaults.standard.string(forKey: "TruffleBufferHands") == "off" { verdict = .wait }
                #endif
                if verdict != .wait || now - lastLogged >= 5 {
                    lastLogged = now
                    let fill = sample.fill.map { String(format: "%.1fx", $0) } ?? "no rate yet"
                    Logger.player.info("[buffer] \(String(describing: verdict), privacy: .public) after \(now, format: .fixed(precision: 1))s: \(sample.ahead, format: .fixed(precision: 1))s buffered, filling at \(fill, privacy: .public), \(bytes / 1000) KB in, \(sample.idle, format: .fixed(precision: 0))s since any arrived, started early \(tries.starts)x, \(mode.rawValue, privacy: .public), AVPlayer: \(self.player.reasonForWaitingToPlay?.rawValue ?? "no reason", privacy: .public)")
                }
                switch verdict {
                case .wait:
                    continue
                case .start:
                    self.silence?.record.did("started with \(Int(sample.ahead)) s in hand")
                    self.bufferTries = (track.id, tries.starts + 1, tries.reconnects)
                    self.player.playImmediately(atRate: 1)
                case .lighter:
                    self.playLighterStream(of: track)
                case .reconnect:
                    self.bufferTries = (track.id, tries.starts, tries.reconnects + 1)
                    self.reconnectStuckSong(item)
                }
                break
            }
            if let self, self.bufferWatch?.item == id { self.bufferWatch = nil }
        }
        bufferWatch = (id, task)
    }

    /// The original is arriving slower than it plays. The song carries on from where it is as Plex's 192 kbps
    /// stream, and so do the next ones, until the connection has had time to change (`WeakSignal`).
    private func playLighterStream(of track: Track) {
        let rest = weakSignal.fellBehind(at: .now)
        silence?.record.did("moved to the lighter stream")
        Logger.player.info("[buffer] \"\(track.title, privacy: .public)\" can't keep up as \(track.codec ?? "the original", privacy: .public); lighter stream from \(Int(self.currentTime))s, and for the next \(Int(rest / 60)) min")
        load(autoplay: true, startTime: currentTime)
    }

    /// Twice a second while the song plays or waits. Written only when it moves a whole percent, so the
    /// player isn't redrawn for nothing.
    private func refreshBuffered() {
        let info = playingItem.flatMap { itemInfo[ObjectIdentifier($0)] }
        var fraction = 0.0
        if let info, info.onPhone {
            fraction = 1
        } else if let item = playingItem, let info {
            let length = Self.length(of: item, track: info.track)
            if length > 0 { fraction = min(1, max(0, Self.buffered(item).end / length)) }
            // The last second or so never reports as loaded.
            if length > 0, Self.buffered(item).end >= length - 1 { fraction = 1 }
        }
        if playsFromPhone != (info?.onPhone ?? false) { playsFromPhone = info?.onPhone ?? false }
        if abs(fraction - bufferedFraction) >= 0.01 || (fraction == 1) != (bufferedFraction == 1) { bufferedFraction = fraction }
    }

    /// How far the song is buffered: seconds past where it will play from, and the time it's buffered up to.
    private static func buffered(_ item: AVPlayerItem) -> (ahead: TimeInterval, end: TimeInterval) {
        let now = item.currentTime().seconds
        guard now.isFinite else { return (0, 0) }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            if start.isFinite, end.isFinite, now >= start - 0.5, now <= end + 0.5 { return (max(0, end - now), end) }
        }
        return (0, now)
    }

    /// Nothing arrived for a while: the connection is dead (the phone changed networks, or sat suspended).
    /// Find the server again and load the song from where it was. It never skips the song: with no signal at
    /// all, every song would go the same way.
    private func reconnectStuckSong(_ item: AVPlayerItem) {
        let resumeAt = currentTime
        Logger.player.error("[buffer] nothing arriving for \"\(self.current?.title ?? "?", privacy: .public)\" at \(Int(resumeAt))s; finding the server again")
        Task {
            let sw = Stopwatch()
            await library.reconnect(reason: "playback stuck")
            guard playingItem === item, playWhenReady else { return }
            guard library.client != nil else {
                silence?.record.did("nothing arrived for \(Int(Buffering.patience)) s and no server address answered")
                Logger.player.error("[buffer] no address answered in \(sw.ms, format: .fixed(precision: 0))ms; the song keeps waiting")
                return
            }
            Logger.player.info("[buffer] reconnected in \(sw.ms, format: .fixed(precision: 0))ms; loading the song again from \(Int(resumeAt))s")
            silence?.record.did("nothing arrived for \(Int(Buffering.patience)) s, found the server again")
            load(autoplay: true, startTime: resumeAt)
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            Logger.player.info("[player] interruption began (playing=\(self.playWhenReady))")
            if playWhenReady { CarLog.shared.note("Other audio took over (a call, Siri, another app); paused") }
            wasPlayingBeforeInterruption = playWhenReady
            pause()
        case .ended:
            Logger.player.info("[player] interruption ended shouldResume=\(options.contains(.shouldResume))")
            if wasPlayingBeforeInterruption {
                CarLog.shared.note(options.contains(.shouldResume) ? "Other audio finished; playing again" : "Other audio finished; iOS didn't ask to resume, still paused")
            }
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
        cacheAheadDelay?.cancel()
        cacheAheadDelay = nil
        // Paused, it goes now: the app may be suspended any second, and the car needs that song tomorrow.
        guard playWhenReady else {
            cacheWindow()
            return
        }
        // Playing, a run of skips settles first, so only where it lands downloads (full FLACs, each skip
        // would otherwise start one and cancel another, all competing with the song that's playing).
        cacheAheadDelay = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.cacheWindow()
        }
    }

    private func cacheWindow() {
        guard !library.isDemo, let client = library.client, let current = queue.current else { return }
        // A song that's playing as a stream is already coming down once; saving it too would halve what the
        // stream gets. Paused, it's saved: it's what the car starts on tomorrow.
        var streamed: [Track] = []
        if playWhenReady, playingItem.flatMap({ itemInfo[ObjectIdentifier($0)] })?.onPhone == false { streamed.append(current) }
        // On cellular the same goes for the song readied behind it, which the player is loading itself. Saving
        // it too fetched it twice: the songs saved are the ones after that, and each plays from its file.
        if playWhenReady, network.isMetered, let next = readiedNext.flatMap({ itemInfo[ObjectIdentifier($0)] }), !next.onPhone {
            streamed.append(next.track)
        }
        updateSaving()
        // Data Saver is someone watching their data: originals don't come down over cellular for them.
        SongCache.shared.want([current] + queue.upcoming.prefix(SongCache.ahead), client: client, notStarting: streamed,
                              droppingThose: network.isMetered, overCellular: settings.saveOnCellular && !settings.dataSaver)
    }

    /// The song readied behind the one playing, on either deck.
    private var readiedNext: AVPlayerItem? { nextItem?.item ?? staged?.item }

    /// On cellular the player eats first. Songs save behind it only while it has all it needs: the song
    /// playing and the one readied after it are in hand to their ends, nothing is waiting to play, and the
    /// signal isn't too weak for originals at all. Saving at the same time as the player loads split the
    /// connection, and in the simulator a drive with it on had more silence than one with it off
    /// (`scripts/road_test.py`, 2026-11-26: LTE then a dead zone, 3.6 s against 0 s). Wi-Fi has room for both.
    private var playerHasWhatItNeeds: Bool {
        guard playWhenReady, network.isMetered else { return true }
        if silence != nil || weakSignal.isWeak(at: .now) { return false }
        return isInHand(playingItem) && isInHand(readiedNext)
    }

    private func isInHand(_ item: AVPlayerItem?) -> Bool {
        guard let item, let info = itemInfo[ObjectIdentifier(item)], !info.onPhone else { return true }
        // The lighter stream comes a few segments at a time, never whole.
        guard info.mode == .original else { return false }
        let length = Self.length(of: item, track: info.track)
        return length > 0 && Self.buffered(item).end >= length - 1
    }

    private func updateSaving() {
        let free = playerHasWhatItNeeds
        guard free != savingIsFree else { return }
        savingIsFree = free
        Logger.player.info("[cache] \(free ? "the player has what it needs; songs can save behind it" : "the player needs the connection; saving waits", privacy: .public)")
        SongCache.shared.yield(!free)
        if free { cacheAhead() }
    }

    /// For the car log: where a resume picks up, without naming the song.
    var resumePlace: String {
        let minutes = Int(currentTime) / 60
        let seconds = Int(currentTime) % 60
        let kind = isEndless ? "endless shuffle" : (source?.kind.rawValue ?? "queue")
        return "song \(queue.index + 1) of \(queue.tracks.count), \(minutes):\(String(format: "%02d", seconds)) in, \(kind), repeat \(queue.repeatMode.rawValue)"
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
        dropRepeatAllIfEndless()
        currentTime = state.time
        pendingSeek = state.time > 1 ? state.time : nil
        needsLoad = true
        Logger.player.info("[player] restored \(state.queue.tracks.count) songs at \(state.queue.index + 1), \(Int(state.time))s into \"\(state.queue.current?.title ?? "", privacy: .public)\"")
    }
}
