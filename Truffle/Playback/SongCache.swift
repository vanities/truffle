import CryptoKit
import Foundation
import os

/// Songs saved on the phone: the one playing (or paused) and the next few, so the car starts from disk in
/// the garage instead of waiting on the server, and a dead zone doesn't stall the next song.
///
/// Downloads run in a background session that only uses Wi-Fi: iOS carries them on while Truffle is
/// suspended, so pausing in the car and walking into the house still saves tomorrow's song. Originals
/// only (Data Saver's transcodes are per-session and expire). Files live in Caches, which iOS may purge
/// under storage pressure; a missing file just streams.
final class SongCache: NSObject, @unchecked Sendable {
    static let shared = SongCache()
    static let sessionIdentifier = "com.vanities.truffle.songs"
    /// The song playing plus this many after it.
    static let ahead = 3
    static let budget: Int64 = 1_000_000_000
    /// A song whose download failed this many times waits for the next launch.
    static let maxFailures = 2

    let directory: URL
    /// A download failed; the player finds the server again and asks once more (`PlayerEngine`).
    @MainActor var onFailure: (() -> Void)?

    /// Unchecked for `finishEvents`: iOS's handler isn't Sendable, and it's taken out once and called on main.
    private struct State: @unchecked Sendable {
        /// File names wanted right now; eviction never touches them.
        var pinned: Set<String> = []
        var failures: [String: Int] = [:]
        /// `urlSessionDidFinishEvents` hands this back so iOS can suspend the app again.
        var finishEvents: (() -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var session: URLSession!

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appending(path: "Songs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        // Not discretionary: on Wi-Fi it should start now, not whenever iOS gets around to it.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let summary = self.summary
        Logger.player.info("[cache] \(summary.count) song(s) on the phone, \(summary.bytes / 1_000_000) MB")
    }

    // MARK: - Reading

    /// The saved file for `track`, if it's all there. Using it marks it recently used.
    func file(for track: Track) -> URL? {
        guard let name = Self.fileName(for: track) else { return nil }
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path())
        return url
    }

    func contains(_ track: Track) -> Bool {
        Self.fileName(for: track).map { FileManager.default.fileExists(atPath: directory.appending(path: $0).path()) } ?? false
    }

    var summary: (count: Int, bytes: Int64) {
        let files = savedFiles()
        return (files.count, files.reduce(0) { $0 + $1.bytes })
    }

    /// A saved file that wouldn't play: it goes, and the song streams.
    func remove(_ track: Track) {
        guard let name = Self.fileName(for: track) else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: name))
        Logger.player.info("[cache] removed \"\(track.title, privacy: .public)\"")
    }

    func removeAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        for file in savedFiles() { try? FileManager.default.removeItem(at: directory.appending(path: file.name)) }
        Logger.player.info("[cache] cleared")
    }

    // MARK: - Downloading

    /// Saves these songs (current first), and stops downloading any song no longer among them. Cheap to call
    /// often: songs already saved or on their way are left alone.
    func want(_ tracks: [Track], client: PlexClient) {
        var wanted: [(name: String, url: URL)] = []
        for track in tracks {
            guard let name = Self.fileName(for: track), let partKey = track.partKey else { continue }
            wanted.append((name, client.streamURL(partKey: partKey)))
        }
        let names = Set(wanted.map(\.name))
        let failures = state.withLock { state in
            state.pinned = names
            return state.failures
        }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            var running: [String: URLSessionTask] = [:]
            for task in tasks {
                guard let name = task.taskDescription else { continue }
                if names.contains(name) {
                    running[name] = task
                } else {
                    task.cancel()
                    Logger.player.debug("[cache] dropped a download no longer coming up")
                }
            }
            var started = 0
            for (name, url) in wanted {
                guard !FileManager.default.fileExists(atPath: self.directory.appending(path: name).path()),
                      (failures[name] ?? 0) < Self.maxFailures else { continue }
                if let task = running[name] {
                    // The server's address changed since (left home, came back): that download would go nowhere.
                    guard task.originalRequest?.url?.host() != url.host() else { continue }
                    task.cancel()
                }
                let task = self.session.downloadTask(with: url)
                task.taskDescription = name
                task.resume()
                started += 1
            }
            if started > 0 {
                Logger.player.info("[cache] saving \(started) song(s) when on Wi-Fi (\(names.count) wanted, \(running.count) already on the way)")
            }
        }
    }

    /// iOS woke the app to finish downloads that ended while it was suspended.
    func handleBackgroundEvents(_ completion: @escaping () -> Void) {
        state.withLock { $0.finishEvents = completion }
        Logger.player.info("[cache] woken for finished downloads")
    }

    private func evict() {
        let pinned = state.withLock { $0.pinned }
        let doomed = Self.evictions(savedFiles(), budget: Self.budget, pinned: pinned)
        for name in doomed { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        if !doomed.isEmpty { Logger.player.info("[cache] made room: removed \(doomed.count) old song(s)") }
    }

    private func savedFiles() -> [CachedFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return CachedFile(name: url.lastPathComponent, bytes: Int64(values.fileSize ?? 0), used: values.contentModificationDate ?? .distantPast)
        }
    }

    // MARK: - Rules

    struct CachedFile: Equatable {
        let name: String
        let bytes: Int64
        let used: Date
    }

    /// The song's id plus a hash of its file's path on the server (a replaced file gets a new one), with
    /// the file's own extension, which AVFoundation reads the format from.
    static func fileName(for track: Track) -> String? {
        guard let partKey = track.partKey, !partKey.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(partKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let ext = (partKey as NSString).pathExtension.lowercased()
        let id = track.id.filter { $0.isLetter || $0.isNumber }
        return "\(id)-\(digest).\(ext.isEmpty ? (track.codec ?? "audio") : ext)"
    }

    /// Least recently used first, until what's left fits; the songs coming up stay.
    static func evictions(_ files: [CachedFile], budget: Int64, pinned: Set<String>) -> [String] {
        var total = files.reduce(0) { $0 + $1.bytes }
        var doomed: [String] = []
        for file in files.sorted(by: { $0.used < $1.used }) where total > budget && !pinned.contains(file.name) {
            total -= file.bytes
            doomed.append(file.name)
        }
        return doomed
    }
}

extension SongCache: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let bytes = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let expected = downloadTask.response?.expectedContentLength ?? -1
        guard status == 200, bytes > 0, expected <= 0 || expected == bytes else {
            Logger.player.error("[cache] download of \(name, privacy: .public) came back \(status), \(bytes)B of \(expected)B; not kept")
            noteFailure(name)
            return
        }
        // The file at `location` is gone once this returns, so it moves now.
        let destination = directory.appending(path: name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Logger.player.info("[cache] saved \(name, privacy: .public), \(bytes / 1_000_000) MB")
        } catch {
            Logger.player.error("[cache] keeping \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        evict()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let name = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        // Domain and code only: the error's URL carries the token.
        let nsError = error as NSError
        Logger.player.error("[cache] download of \(name, privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code)")
        noteFailure(name)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let finish = state.withLock { state in
            defer { state.finishEvents = nil }
            return state.finishEvents
        }
        DispatchQueue.main.async { finish?() }
    }

    private func noteFailure(_ name: String) {
        let count = state.withLock { state in
            state.failures[name, default: 0] += 1
            return state.failures[name] ?? 0
        }
        guard count < Self.maxFailures else { return }
        Task { @MainActor in self.onFailure?() }
    }
}
