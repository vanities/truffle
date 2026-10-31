import Foundation
import Network
import Observation
import os

/// What a song streams as.
enum StreamMode: String, Sendable {
    /// The file on the server, as it is.
    case original
    /// Plex's 192 kbps transcode, over HLS.
    case dataSaver
}

/// Data Saver: on cellular (or a hotspot, which iOS marks expensive) new songs stream as Plex's 192 kbps
/// transcode instead of the original file. Wi-Fi keeps the originals. A transcode that fails never costs
/// the song: it plays the original instead.
enum DataSaver {
    static let kbps = 192

    enum FailureResponse: Equatable, Sendable {
        /// Play the same song from its original file, from where it was.
        case playOriginal
        /// The usual recovery: rebuild and retry, then skip.
        case recover
    }

    static func mode(enabled: Bool, metered: Bool) -> StreamMode {
        enabled && metered ? .dataSaver : .original
    }

    /// The mode for one song: originals while transcodes rest, and for a song whose transcode failed.
    static func mode(enabled: Bool, metered: Bool, song: String, health: TranscodeHealth, now: Date) -> StreamMode {
        guard !health.isResting(at: now), !health.failedSongs.contains(song) else { return .original }
        return mode(enabled: enabled, metered: metered)
    }

    static func onFailure(of mode: StreamMode) -> FailureResponse {
        mode == .dataSaver ? .playOriginal : .recover
    }

    static func isMetered(cellular: Bool, expensive: Bool) -> Bool {
        cellular || expensive
    }
}

/// How Data Saver's transcodes are going this session. On 2026-10-30 PMS 1.43 turned down `start.m3u8`
/// with a 400 now and then, so: a song whose transcode fails plays its original from then on, and after
/// `limit` failures in a row transcodes rest for `rest` before Data Saver tries again.
struct TranscodeHealth: Equatable, Sendable {
    static let limit = 2
    static let rest: TimeInterval = 5 * 60

    /// Rating keys of songs whose transcode failed.
    private(set) var failedSongs: Set<String> = []
    private(set) var failuresInARow = 0
    private(set) var restingUntil: Date?

    func isResting(at now: Date) -> Bool {
        restingUntil.map { now < $0 } ?? false
    }

    /// True when this failure starts a rest.
    @discardableResult
    mutating func failed(_ song: String, at now: Date) -> Bool {
        failedSongs.insert(song)
        failuresInARow += 1
        guard failuresInARow >= Self.limit else { return false }
        failuresInARow = 0
        restingUntil = now.addingTimeInterval(Self.rest)
        return true
    }

    /// A transcode played, so the run of failures is over.
    mutating func played() {
        failuresInARow = 0
    }
}

/// Whether the phone is on a metered connection, for Data Saver.
@MainActor @Observable
final class NetworkCost {
    private(set) var isMetered = false
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var heard = false

    init() {
        #if DEBUG
        // `-TruffleCellular YES`: act as if on cellular, so Data Saver runs in the simulator.
        if UserDefaults.standard.bool(forKey: "TruffleCellular") {
            isMetered = true
            Logger.player.info("[datasaver] network: cellular (forced by -TruffleCellular)")
            return
        }
        #endif
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = DataSaver.isMetered(cellular: path.usesInterfaceType(.cellular), expensive: path.isExpensive)
            Task { @MainActor [weak self] in self?.update(metered) }
        }
        monitor.start(queue: DispatchQueue(label: "truffle.network-cost"))
        self.monitor = monitor
    }

    private func update(_ metered: Bool) {
        let changed = metered != isMetered
        guard changed || !heard else { return }
        heard = true
        isMetered = metered
        Logger.player.info("[datasaver] network: \(metered ? "metered (cellular or hotspot)" : "unmetered", privacy: .public)")
        if changed { onChange?(metered) }
    }
}
