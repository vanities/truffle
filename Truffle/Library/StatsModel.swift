import Foundation
import Observation
import os

/// What Stats saved last time, so opening it again shows numbers before the server answers.
struct StatsCache: Codable, Sendable {
    static let currentVersion = 1

    var version = StatsCache.currentVersion
    var machineIdentifier: String
    var sectionID: String
    /// "1" for the server owner's plays; nil for whatever the server shows this account.
    var accountID: String?
    /// Oldest first, as the server lists them.
    var plays: [PlayRecord] = []
    var songs: [String: SongFacts] = [:]
    var savedAt = Date()
}

/// The Stats tab's numbers. Saved ones show first; then an update reads only what was played since,
/// starting one play early so the overlap proves the saved history still lines up.
@MainActor @Observable
final class StatsModel {
    struct Progress: Equatable {
        var read: Int
        var total: Int?
    }

    private(set) var stats: ListeningStats?
    private(set) var isUpdating = false
    /// Plays read so far, while there's nothing saved to show.
    private(set) var progress: Progress?
    private(set) var errorMessage: String?
    private(set) var updatedAt: Date?

    @ObservationIgnored private let library: MusicLibrary
    @ObservationIgnored private var cache: StatsCache?
    @ObservationIgnored private var cacheKey: String?
    @ObservationIgnored private var running: Task<Void, Never>?

    /// Coming back to the tab within this long doesn't ask the server again.
    private static let freshFor: TimeInterval = 60

    init(library: MusicLibrary) {
        self.library = library
    }

    /// Opening the tab.
    func load() async { await run(force: false) }

    /// Pull to refresh.
    func refresh() async { await run(force: true) }

    /// One update at a time. It isn't the view's task, so leaving the tab doesn't cancel a long first read.
    private func run(force: Bool) async {
        if let running {
            await running.value
            return
        }
        let task = Task { await update(force: force) }
        running = task
        await task.value
        running = nil
    }

    private func update(force: Bool) async {
        guard let section = library.section, let server = library.server else { return }
        let key = [server.machineIdentifier, section.id, library.userName ?? ""].joined(separator: "|")
        if key != cacheKey {
            cacheKey = key
            cache = nil
            stats = nil
            updatedAt = nil
            errorMessage = nil
            await restore(server: server, section: section)
        }
        if !force, let updatedAt, Date.now.timeIntervalSince(updatedAt) < Self.freshFor { return }

        isUpdating = true
        defer {
            isUpdating = false
            progress = nil
        }
        let sw = Stopwatch()
        do {
            let synced = try await sync(cache, server: server, section: section)
            guard cacheKey == key else { return }
            cache = synced
            stats = await Self.build(synced, libraryTrackCount: library.trackCount)
            updatedAt = .now
            errorMessage = nil
            save(synced, section: section)
            Logger.stats.info("[stats] up to date: \(synced.plays.count) plays, \(synced.songs.count) songs in \(sw.ms, format: .fixed(precision: 0))ms")
        } catch is CancellationError {
            Logger.stats.info("[stats] update cancelled after \(sw.ms, format: .fixed(precision: 0))ms")
        } catch {
            errorMessage = error.localizedDescription
            Logger.stats.error("[stats] update failed after \(sw.ms, format: .fixed(precision: 0))ms: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reading

    private func sync(_ saved: StatsCache?, server: PlexServerInfo, section: MusicSection) async throws -> StatsCache {
        let sw = Stopwatch()
        var cache = saved ?? StatsCache(machineIdentifier: server.machineIdentifier, sectionID: section.id,
                                        accountID: MusicLibrary.ownerAccountID)
        var requests = 0
        if cache.accountID == nil, !cache.plays.isEmpty {
            // Saved as "everything this account sees" because the owner had no plays; check they still don't.
            requests += 1
            if let owned = try? await library.historyCount(accountID: MusicLibrary.ownerAccountID), owned > 0 {
                Logger.stats.info("[stats] the owner account has \(owned) plays now; reading those instead")
                cache.plays = []
            }
        }

        let lastSeen = cache.plays.last?.viewedAt ?? Int.min
        var plays: [PlayRecord]
        var named: [String: SongFacts]
        if cache.plays.isEmpty {
            let (read, account) = try await readAll(requests: &requests)
            (plays, named, cache.accountID) = (read.plays, read.named, account)
        } else {
            let read = try await library.readHistory(from: HistorySync.resumeIndex(cached: cache.plays.count),
                                                     accountID: cache.accountID, progress: report)
            requests += read.requests
            if let merged = HistorySync.merge(cached: cache.plays, fetched: read.plays, total: read.total) {
                (plays, named) = (merged, read.named)
            } else {
                Logger.stats.info("[stats] history moved under the saved copy (\(cache.plays.count) saved, \(read.total.map(String.init) ?? "?", privacy: .public) on the server); reading it all")
                let (all, account) = try await readAll(requests: &requests)
                (plays, named, cache.accountID) = (all.plays, all.named, account)
            }
        }

        // New songs, and songs played since last time (Plex's counts for those moved).
        let ids = Set(plays.map(\.trackID))
        let playedSince = Set(plays.lazy.filter { $0.viewedAt > lastSeen }.map(\.trackID))
        let wanted = ids.subtracting(cache.songs.keys).union(playedSince)
        let looked = try await library.songFacts(for: wanted.sorted())
        requests += looked.requests
        var songs = cache.songs.filter { ids.contains($0.key) }
        for id in wanted {
            if let found = looked.facts[id] {
                songs[id] = found
            } else if let gone = named[id] {
                songs[id] = gone
            }
        }

        let added = plays.count - cache.plays.count
        cache.plays = plays
        cache.songs = songs
        cache.savedAt = .now
        Logger.stats.info("[stats] synced \(plays.count) plays (\(added >= 0 ? "+" : "")\(added)), looked up \(wanted.count) songs, \(requests) requests in \(sw.ms, format: .fixed(precision: 0))ms")
        return cache
    }

    /// The whole history: the server owner's plays, or, when the owner has none, everything the server
    /// shows this account (on a server you don't own that should be your own plays; not checked against
    /// a real shared server).
    private func readAll(requests: inout Int) async throws -> (HistoryRead, String?) {
        let owner = MusicLibrary.ownerAccountID
        var mine: HistoryRead?
        do {
            let read = try await library.readHistory(from: 0, accountID: owner, progress: report)
            requests += read.requests
            if !read.plays.isEmpty { return (read, owner) }
            mine = read
        } catch let error as PlexError {
            Logger.stats.info("[stats] owner history refused (\(error.localizedDescription, privacy: .public)); reading unfiltered")
        }
        let everyone = try await library.readHistory(from: 0, accountID: nil, progress: report)
        requests += everyone.requests
        if everyone.plays.isEmpty, let mine { return (mine, owner) }
        Logger.stats.info("[stats] no plays as the owner; using the \(everyone.plays.count) this account sees")
        return (everyone, nil)
    }

    private func report(read: Int, total: Int?) {
        guard stats == nil else { return }
        progress = Progress(read: read, total: total)
    }

    // MARK: - Saving

    private static func fileName(_ section: MusicSection) -> String { "stats-\(section.id).json" }

    private func restore(server: PlexServerInfo, section: MusicSection) async {
        let sw = Stopwatch()
        let store = library.store
        let name = Self.fileName(section)
        let saved = await Task.detached(priority: .userInitiated) { store.load(StatsCache.self, from: name) }.value
        guard let saved else {
            Logger.stats.info("[stats] nothing saved for section \(section.id, privacy: .public)")
            return
        }
        guard saved.version == StatsCache.currentVersion, saved.machineIdentifier == server.machineIdentifier,
              saved.sectionID == section.id else {
            Logger.stats.info("[stats] saved stats are for another server or version; starting over")
            return
        }
        cache = saved
        stats = await Self.build(saved, libraryTrackCount: library.trackCount)
        Logger.stats.info("[stats] restored \(saved.plays.count) plays, \(saved.songs.count) songs from \(saved.savedAt.formatted(.relative(presentation: .named)), privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    private func save(_ cache: StatsCache, section: MusicSection) {
        let store = library.store
        let name = Self.fileName(section)
        Task.detached(priority: .utility) { store.save(cache, to: name) }
    }

    private static func build(_ cache: StatsCache, libraryTrackCount: Int) async -> ListeningStats {
        await Task.detached(priority: .userInitiated) {
            let sw = Stopwatch()
            let stats = ListeningStats.build(plays: cache.plays, songs: cache.songs, libraryTrackCount: libraryTrackCount)
            Logger.stats.info("[stats] worked out from \(cache.plays.count) plays in \(sw.ms, format: .fixed(precision: 1))ms")
            return stats
        }.value
    }
}
