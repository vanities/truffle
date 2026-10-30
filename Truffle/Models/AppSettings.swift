import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Levels songs to the same loudness from Plex's analysis. On by default: a true shuffle
    /// across a whole library jumps between masters cut decades apart.
    var evenOutVolume: Bool { didSet { defaults.set(evenOutVolume, forKey: Keys.evenOutVolume) } }
    var hemisphere: Hemisphere { didSet { defaults.set(hemisphere.rawValue, forKey: Keys.hemisphere) } }
    /// Falling leaves, snow and the rest. Reduce Motion turns them off regardless.
    var seasonalEffects: Bool { didSet { defaults.set(seasonalEffects, forKey: Keys.seasonalEffects) } }
    /// The music library chosen on the server (picked automatically the first time).
    var sectionID: String? { didSet { defaults.set(sectionID, forKey: Keys.sectionID) } }

    private enum Keys {
        static let evenOutVolume = "settings.evenOutVolume"
        static let hemisphere = "settings.hemisphere"
        static let seasonalEffects = "settings.seasonalEffects"
        static let sectionID = "settings.sectionID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        evenOutVolume = defaults.object(forKey: Keys.evenOutVolume) as? Bool ?? true
        hemisphere = defaults.string(forKey: Keys.hemisphere).flatMap(Hemisphere.init(rawValue:)) ?? .automatic
        seasonalEffects = defaults.object(forKey: Keys.seasonalEffects) as? Bool ?? true
        sectionID = defaults.string(forKey: Keys.sectionID)
    }

    var isSouthern: Bool { hemisphere.isSouthern() }
}
