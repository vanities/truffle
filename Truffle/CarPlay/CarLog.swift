import Foundation
import Observation
import UIKit
import os

/// What happened each time the car might have started music, kept across launches (Settings, Car Log).
/// "Play in the Car" works only sometimes, and there are three ways in: the car screen opening Truffle
/// (`CarPlaySceneDelegate`), iOS or the car sending Play to the last app that played (`NowPlayingController`,
/// often to a cold launch with no screen), and the Resume shortcut. A missing line says which one never came.
/// Counts and states only, no song names.
@MainActor @Observable
final class CarLog {
    static let shared = CarLog()
    static let limit = 300
    /// How long a start may take before it's written down as silent.
    static let patience: Duration = .seconds(45)

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id: Date { date }
        let date: Date
        let text: String
    }

    private(set) var entries: [Entry]
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var waiting: (trigger: String, since: ContinuousClock.Instant, watch: Task<Void, Never>)?
    private static let file = "car-log.json"

    init(store: LibraryStore = LibraryStore()) {
        self.store = store
        entries = store.load([Entry].self, from: Self.file) ?? []
    }

    func note(_ text: String) {
        Logger.carplay.info("[carlog] \(text, privacy: .public)")
        entries = Self.appending(Entry(date: .now, text: text), to: entries)
        store.save(entries, to: Self.file)
    }

    /// Something should start playing now; the next sound (or its absence) gets a line with how long it took.
    func expectSound(after trigger: String, state: @escaping @MainActor () -> String) {
        waiting?.watch.cancel()
        let watch = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled, let self, self.waiting?.trigger == trigger else { return }
            self.waiting = nil
            self.note("No sound \(Int(Self.patience.components.seconds)) s after \(trigger): \(state())")
        }
        waiting = (trigger, .now, watch)
    }

    func soundStarted(fromPhone: Bool) {
        guard let waiting else { return }
        self.waiting = nil
        waiting.watch.cancel()
        let elapsed = ContinuousClock.now - waiting.since
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        note(String(format: "Sound %.1f s after %@, %@", seconds, waiting.trigger, fromPhone ? "from the phone" : "streamed"))
    }

    func clear() {
        entries = []
        store.remove(Self.file)
    }

    var text: String {
        let format = Date.FormatStyle(date: .abbreviated, time: .standard)
        return entries.map { "\($0.date.formatted(format))  \($0.text)" }.joined(separator: "\n")
    }

    static func appending(_ entry: Entry, to entries: [Entry]) -> [Entry] {
        Array((entries + [entry]).suffix(limit))
    }
}

extension UIApplication.State {
    var carLogName: String {
        switch self {
        case .active: "open"
        case .inactive: "opening"
        case .background: "in the background"
        @unknown default: "in an unknown state"
        }
    }
}
