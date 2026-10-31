import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.vanities.truffle"

    static let plex = Logger(subsystem: subsystem, category: "plex")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let shuffle = Logger(subsystem: subsystem, category: "shuffle")
    static let mixes = Logger(subsystem: subsystem, category: "mixes")
    static let player = Logger(subsystem: subsystem, category: "player")
    static let nowPlaying = Logger(subsystem: subsystem, category: "nowplaying")
    static let carplay = Logger(subsystem: subsystem, category: "carplay")
    static let artwork = Logger(subsystem: subsystem, category: "artwork")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let demo = Logger(subsystem: subsystem, category: "demo")
}

/// Cheap elapsed-time helper for log lines: `let sw = Stopwatch(); ...; sw.ms`.
struct Stopwatch: Sendable {
    let start = Date()
    var seconds: TimeInterval { Date().timeIntervalSince(start) }
    var ms: Double { seconds * 1000 }
}
