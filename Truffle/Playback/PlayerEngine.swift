import AVFoundation
import Foundation
import Observation
import os

/// What's playing, as the user picked it.
struct PlaySource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case album, artist, playlist, mix, shuffleAll, liked, search, songs
    }

    var kind: Kind
    var title: String
    var id: String?
    /// An album played front to back keeps the album's own loudness (see `Loudness`).
    var albumInOrder = false

    static let shuffleAll = PlaySource(kind: .shuffleAll, title: "Shuffle All")
}

/// The queue saved between launches, so the car's play button picks up where you left off.
struct PlayerState: Codable, Sendable {
    var queue: PlayQueue
    var time: TimeInterval
    var source: PlaySource?
    var feed: ShuffleFeed?
    var savedAt: Date
}

/// Plays the queue through an AVQueuePlayer holding the current song and the next one, so songs
/// run into each other without a gap.
@MainActor @Observable
final class PlayerEngine {
    private(set) var queue = PlayQueue()
    private(set) var source: PlaySource?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var errorMessage: String?
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
    @ObservationIgnored private let reporter: PlexReporter
    @ObservationIgnored private let player = AVQueuePlayer()
    /// The preloaded item and the queue position it plays.
    @ObservationIgnored private var nextItem: (item: AVPlayerItem, index: Int)?
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
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var enriching: Set<String> = []
    /// The song each loaded item plays; a natural end reports that song as played.
    @ObservationIgnored private var itemTracks: [ObjectIdentifier: Track] = [:]
    /// One failure is often reported twice (status and notification); count it once.
    @ObservationIgnored private var failedItem: ObjectIdentifier?

    private static let stateFile = "player.json"

    init(library: MusicLibrary, settings: AppSettings) {
        self.library = library
        self.settings = settings
        reporter = PlexReporter(library: library)
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        installObservers()
        restore()
        library.onEndpointChanged = { [weak self] endpoint in self?.endpointChanged(endpoint) }
        library.onSignedOut = { [weak self] in self?.stop(clearing: true) }
        library.onTrackUpdated = { [weak self] track in
            guard let self else { return }
            self.queue.update(track)
            self.notify()
        }
    }

    // MARK: - Starting things

    func play(_ tracks: [Track], startAt index: Int = 0, source: PlaySource, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        var list = tracks
        var start = index
        if shuffled {
            list.shuffle()
            start = 0
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
        let source = PlaySource(kind: .playlist, title: playlist.title, id: playlist.id)
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
            errorMessage = "Couldn't load \(playlist.title): \(error.localizedDescription)"
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
                errorMessage = "Your library is empty."
                notify()
                return
            }
            feed = newFeed
            source = newSource
            queue.replace(with: tracks, startAt: 0)
            load(autoplay: true)
        } catch {
            isLoading = false
            errorMessage = "Couldn't start the shuffle: \(error.localizedDescription)"
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
            if mix.kind == .randomAlbum, let (album, tracks) = try await library.randomAlbumTracks() {
                play(tracks, source: PlaySource(kind: .album, title: album.title, id: album.id, albumInOrder: true))
                return
            }
            let tracks = try await library.tracks(for: mix, theme: theme)
            guard !tracks.isEmpty else {
                isLoading = false
                errorMessage = "Nothing in \(mix.title) yet."
                notify()
                return
            }
            play(tracks, source: PlaySource(kind: mix.kind == .liked ? .liked : .mix, title: mix.title, id: mix.id))
        } catch {
            isLoading = false
            errorMessage = "Couldn't load \(mix.title): \(error.localizedDescription)"
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
        reportStopped()
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
        reportStopped()
        if let preloaded = nextItem, preloaded.index == index, player.items().count > 1 {
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
        reportStopped()
        queue.move(to: index)
        load(autoplay: true)
    }

    func seek(to time: TimeInterval) {
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
            errorMessage = "Couldn't update the like: \(error.localizedDescription)"
            notify()
        }
    }

    /// Signing out, or the queue emptied.
    func stop(clearing: Bool) {
        reportStopped()
        player.pause()
        player.removeAllItems()
        nextItem = nil
        playWhenReady = false
        isPlaying = false
        isLoading = false
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
        player.removeAllItems()
        nextItem = nil
        guard let item = makeItem(for: track) else {
            // Not connected yet: connect, then try again.
            needsLoad = true
            isLoading = autoplay
            playWhenReady = autoplay
            notify()
            Task {
                await library.reconnect(reason: "play")
                if library.client != nil, needsLoad { load(autoplay: playWhenReady, startTime: startTime) }
                else if needsLoad {
                    isLoading = false
                    errorMessage = "Can't reach \(library.serverName) right now."
                    notify()
                }
            }
            return
        }
        currentItemBase = library.endpoint?.baseURL
        player.insert(item, after: nil)
        itemTracks = [ObjectIdentifier(item): track]
        failedItem = nil
        observe(item)
        currentTime = startTime
        pendingSeek = startTime > 1 ? startTime : nil
        applyVolume()
        preloadNext()
        recoveryAttempts = 0
        Logger.player.info("[player] load \(self.queue.index + 1)/\(self.queue.tracks.count) \"\(track.title, privacy: .public)\" by \(track.artist, privacy: .public) [\(track.codec ?? "?", privacy: .public)] autoplay=\(autoplay)")
        if autoplay {
            isLoading = true
            play()
        }
        enrichSoon()
        topUpIfNeeded()
        save()
        notify()
    }

    private func makeItem(for track: Track) -> AVPlayerItem? {
        guard let client = library.client, let partKey = track.partKey else { return nil }
        let asset = AVURLAsset(url: client.streamURL(partKey: partKey))
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        return item
    }

    /// Keeps the song after the current one loaded in the AVQueuePlayer (none for Repeat One, which
    /// replays the current song when it ends).
    private func preloadNext() {
        if let existing = nextItem {
            player.remove(existing.item)
            itemTracks[ObjectIdentifier(existing.item)] = nil
            nextItem = nil
        }
        guard queue.repeatMode != .one, let index = queue.indexAfterEnd(), let track = queue.tracks[safe: index],
              let current = player.currentItem, let item = makeItem(for: track) else { return }
        player.insert(item, after: current)
        itemTracks[ObjectIdentifier(item)] = track
        nextItem = (item, index)
        Logger.player.debug("[player] preloaded \(index + 1): \(track.title, privacy: .public)")
    }

    /// The AVQueuePlayer moved on by itself (a song ended and the preloaded one started).
    private func currentItemChanged() {
        guard let item = player.currentItem else { return }
        if let preloaded = nextItem, preloaded.item === item {
            // No play report here: a skip to the preloaded song lands here too (see itemEnded).
            let loaded = Set(player.items().map(ObjectIdentifier.init))
            itemTracks = itemTracks.filter { loaded.contains($0.key) }
            failedItem = nil
            queue.move(to: preloaded.index)
            nextItem = nil
            currentItemBase = library.endpoint?.baseURL
            observe(item)
            currentTime = 0
            applyVolume()
            preloadNext()
            trimHistory()
            enrichSoon()
            topUpIfNeeded()
            save()
            Logger.player.info("[player] advanced to \(self.queue.index + 1)/\(self.queue.tracks.count) \"\(self.current?.title ?? "", privacy: .public)\"")
            notify()
        }
    }

    /// The current song ended with nothing preloaded: Repeat One, an endless shuffle that ran dry,
    /// or the end of the queue.
    private func itemEnded(_ item: AVPlayerItem) {
        // Only a song that played to its end lands here, so this is what counts as a play.
        if let track = itemTracks[ObjectIdentifier(item)] {
            reporter.report(.stopped, track: track, time: track.duration)
        }
        // With a song preloaded, the queue player has already moved on (currentItemChanged).
        guard nextItem == nil else { return }
        if queue.repeatMode == .one {
            Logger.player.info("[player] repeat one")
            player.seek(to: .zero)
            player.play()
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
        var volume = settings.evenOutVolume ? Loudness.volume(for: track, albumMode: source?.albumInOrder == true) : 1
        #if DEBUG
        // `-TruffleMute YES`: test runs against a real library play silently.
        if UserDefaults.standard.bool(forKey: "TruffleMute") { volume = 0 }
        #endif
        player.volume = volume
        Logger.player.debug("[player] volume \(volume, format: .fixed(precision: 2)) (loudness \(track.loudness ?? .nan, format: .fixed(precision: 1)))")
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
        guard player.currentItem != nil else { return }
        preloadNext()
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate, currentItemBase != endpoint.baseURL {
            rebuildCurrent(reason: "stalled on the old address")
        }
    }

    private func rebuildCurrent(reason: String) {
        let resume = playWhenReady
        Logger.player.info("[player] rebuilding current item at \(Int(self.currentTime))s: \(reason, privacy: .public)")
        load(autoplay: resume, startTime: currentTime)
    }

    private func itemFailed(_ item: AVPlayerItem, _ error: (any Error)?) {
        guard item === player.currentItem, failedItem != ObjectIdentifier(item) else { return }
        failedItem = ObjectIdentifier(item)
        let message = error?.localizedDescription ?? "unknown error"
        Logger.player.error("[player] item failed (attempt \(self.recoveryAttempts + 1)): \(message, privacy: .public)")
        recoveryAttempts += 1
        guard recoveryAttempts <= 2 else {
            errorMessage = "Couldn't play \(current?.title ?? "this song")."
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
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(CMTimeGetSeconds(time)) }
        }
        playerObservers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncPlayingState() }
        })
        playerObservers.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.currentItemChanged() }
        })
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
        observers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Logger.player.info("[player] stalled")
                if let endpoint = self.library.endpoint, endpoint.baseURL != self.currentItemBase {
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
        guard item === player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if let seek = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                Logger.player.info("[player] resumed at \(Int(seek))s")
            }
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
            reporter.report(.playing, track: track, time: seconds)
            if ticks % 20 == 0 { save() }
        }
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
            if let track = current { reporter.report(.playing, track: track, time: currentTime) }
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

    private func reportStopped() {
        guard let track = current, player.currentItem != nil else { return }
        reporter.report(.stopped, track: track, time: currentTime)
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
