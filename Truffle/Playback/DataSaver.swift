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
/// transcode instead of the original file. Wi-Fi keeps the originals.
enum DataSaver {
    static let kbps = 192

    static func mode(enabled: Bool, metered: Bool) -> StreamMode {
        enabled && metered ? .dataSaver : .original
    }

    static func isMetered(cellular: Bool, expensive: Bool) -> Bool {
        cellular || expensive
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
