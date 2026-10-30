import Foundation
import os

/// What the library looked like last time, so the app (and the car) has lists the moment it
/// opens, before the server answers.
struct LibrarySnapshot: Codable, Sendable {
    var machineIdentifier: String
    var sectionID: String
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var recentlyAdded: [Album] = []
    var trackCount = 0
    var likedCount = 0
    var savedAt = Date()
}

/// JSON files in Application Support: the library snapshot, the shuffle walk, the player's queue.
struct LibraryStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
        self.directory = base.appending(path: "Truffle", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appending(path: name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Logger.store.error("[store] \(name, privacy: .public) unreadable (\(data.count)B): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, to name: String) {
        let sw = Stopwatch()
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: directory.appending(path: name), options: .atomic)
            Logger.store.debug("[store] saved \(name, privacy: .public) \(data.count)B in \(sw.ms, format: .fixed(precision: 1))ms")
        } catch {
            Logger.store.error("[store] saving \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }

    func removeAll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        for name in names { remove(name) }
    }
}
