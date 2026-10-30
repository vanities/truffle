import Foundation
import UIKit
import os

/// Album art from the server's resizer, kept in memory and in Caches. Keys are the art's path and
/// size, never the server address or token, so the same cover survives a connection change.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = caches.appending(path: "artwork", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    func image(thumb: String, size: Int, client: PlexClient) async -> UIImage? {
        let key = Self.key(thumb: thumb, size: size)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = inflight[key] { return await running.value }
        let file = directory.appending(path: key + ".jpg")
        let task = Task<UIImage?, Never> {
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data)?.preparingForDisplay() {
                return image
            }
            let sw = Stopwatch()
            do {
                let (data, response) = try await client.session.data(from: client.artworkURL(thumb, size: size))
                guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data)?.preparingForDisplay() else {
                    Logger.artwork.info("[artwork] \(thumb, privacy: .public)@\(size) unavailable")
                    return nil
                }
                try? data.write(to: file, options: .atomic)
                Logger.artwork.debug("[artwork] fetched \(thumb, privacy: .public)@\(size) \(data.count)B in \(sw.ms, format: .fixed(precision: 0))ms")
                return image
            } catch {
                Logger.artwork.info("[artwork] \(thumb, privacy: .public)@\(size) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    /// FNV-1a: stable across launches, unlike `Hasher`, which is seeded per process.
    nonisolated static func key(thumb: String, size: Int) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(thumb)@\(size)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
