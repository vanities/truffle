import Foundation
import os

/// Plays read from the server's history, oldest first.
struct HistoryRead: Sendable {
    var plays: [PlayRecord] = []
    /// Songs as their history entries name them: what's left of a song once it leaves the library.
    var named: [String: SongFacts] = [:]
    var total: Int?
    var requests = 0

    /// Songs only (a music section's history has nothing else, but a stray entry shouldn't count), and
    /// only entries that say when.
    mutating func add(_ entries: [PlexMetadata]) {
        for entry in entries where entry.type == nil || entry.type == "track" {
            guard !entry.ratingKey.isEmpty, let viewedAt = entry.viewedAt else { continue }
            plays.append(PlayRecord(trackID: entry.ratingKey, viewedAt: viewedAt))
            named[entry.ratingKey] = SongFacts(entry, inLibrary: false)
        }
    }
}

extension MusicLibrary {
    /// The server owner on their own server. History there holds every account's plays.
    nonisolated static let ownerAccountID = "1"

    nonisolated private static let historyPath = "/status/sessions/history/all"

    /// History from position `start` to the end, oldest first (so new plays only ever append), a page at a
    /// time with a few pages in flight once the first page says how many there are.
    func readHistory(from start: Int, accountID: String?, pageSize: Int = 1000, inFlight: Int = 4,
                     progress: @MainActor (_ read: Int, _ total: Int?) -> Void = { _, _ in }) async throws -> HistoryRead {
        guard let section else { return HistoryRead() }
        let sw = Stopwatch()
        let base = PlexQuery([("librarySectionID", section.id), ("sort", "viewedAt:asc")])
        let query = accountID.map { base.with("accountID", $0) } ?? base
        let read = try await withClient("history") { client in
            let page: @Sendable (Int) async throws -> [PlexMetadata] = { offset in
                try await client.get(Self.historyPath, query.page(start: offset, size: pageSize)).metadata
            }
            var read = HistoryRead()
            let first = try await client.get(Self.historyPath, query.page(start: start, size: pageSize))
            var pages = [start: first.metadata]
            var count = first.metadata.count
            read.requests = 1
            read.total = first.totalSize
            progress(count, first.totalSize.map { max(0, $0 - start) })
            if let total = first.totalSize {
                var pending = HistorySync.pageStarts(after: start, size: pageSize, total: total)[...]
                try await withThrowingTaskGroup(of: (Int, [PlexMetadata]).self) { group in
                    for _ in 0..<min(inFlight, pending.count) {
                        let offset = pending.removeFirst()
                        group.addTask { (offset, try await page(offset)) }
                    }
                    while let done = try await group.next() {
                        pages[done.0] = done.1
                        count += done.1.count
                        read.requests += 1
                        progress(count, total - start)
                        if let offset = pending.popFirst() {
                            group.addTask { (offset, try await page(offset)) }
                        }
                    }
                }
            } else {
                // No totalSize to plan with: read on until a short page.
                var offset = start
                while pages[offset]?.count == pageSize {
                    offset += pageSize
                    pages[offset] = try await page(offset)
                    count += pages[offset]?.count ?? 0
                    read.requests += 1
                    progress(count, nil)
                }
            }
            for offset in pages.keys.sorted() {
                read.add(pages[offset] ?? [])
            }
            return read
        }
        Logger.stats.info("[stats] history from \(start) account=\(accountID ?? "any", privacy: .public): \(read.plays.count) plays of \(read.total.map(String.init) ?? "?", privacy: .public) in \(read.requests) requests, \(sw.ms, format: .fixed(precision: 0))ms")
        return read
    }

    /// How many plays an account has, without reading them: a page of size 0 still carries totalSize.
    func historyCount(accountID: String?) async throws -> Int? {
        guard let section else { return nil }
        let base = PlexQuery([("librarySectionID", section.id)])
        let query = accountID.map { base.with("accountID", $0) } ?? base
        return try await withClient("history count") { try await $0.get(Self.historyPath, query.page(start: 0, size: 0)) }.totalSize
    }

    /// What Stats needs about each song (length, names, Plex's own play count and last play), `batch` ids a
    /// request with a few in flight. Songs that have left the library just don't come back.
    func songFacts(for ids: [String], batch: Int = 100, inFlight: Int = 4) async throws -> (facts: [String: SongFacts], requests: Int) {
        guard !ids.isEmpty else { return ([:], 0) }
        let sw = Stopwatch()
        let lists = stride(from: 0, to: ids.count, by: batch).map { ids[$0..<min($0 + batch, ids.count)].joined(separator: ",") }
        let result = try await withClient("song facts") { client in
            let details: @Sendable (String) async throws -> [PlexMetadata] = { list in
                do {
                    return try await client.get("/library/metadata/\(list)").metadata
                } catch PlexError.http(let status, _) where status == 404 {
                    return []
                }
            }
            var facts: [String: SongFacts] = [:]
            var requests = 0
            var pending = lists[...]
            try await withThrowingTaskGroup(of: [PlexMetadata].self) { group in
                for _ in 0..<min(inFlight, pending.count) {
                    let list = pending.removeFirst()
                    group.addTask { try await details(list) }
                }
                while let items = try await group.next() {
                    requests += 1
                    for item in items {
                        if let song = SongFacts(item) { facts[item.ratingKey] = song }
                    }
                    if let list = pending.popFirst() {
                        group.addTask { try await details(list) }
                    }
                }
            }
            return (facts, requests)
        }
        Logger.stats.info("[stats] song details: \(result.0.count) of \(ids.count) in the library, \(result.1) requests, \(sw.ms, format: .fixed(precision: 0))ms")
        return result
    }
}
