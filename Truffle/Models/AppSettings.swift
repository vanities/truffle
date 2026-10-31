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
    /// Starts the music when CarPlay connects and nothing's playing (`CarAutoplay`).
    var playInTheCar: Bool { didSet { defaults.set(playInTheCar, forKey: Keys.playInTheCar) } }
    /// Shuffle All and Album Roulette leave holiday music for the holidays (`HolidayMusic`).
    var holidaysInSeason: Bool { didSet { defaults.set(holidaysInSeason, forKey: Keys.holidaysInSeason) } }
    /// The music library chosen on the server (picked automatically the first time).
    var sectionID: String? { didSet { defaults.set(sectionID, forKey: Keys.sectionID) } }
    var appIcon: AppIconChoice { didSet { defaults.set(appIcon.rawValue, forKey: Keys.appIcon) } }
    /// The note icon in the fall, whatever `appIcon` says.
    var seasonalIcon: Bool { didSet { defaults.set(seasonalIcon, forKey: Keys.seasonalIcon) } }
    /// Seconds two shuffled songs overlap; 0 is off. Albums, and anything else played in order, stay
    /// gapless (see `Crossfade`).
    var crossfadeSeconds: Int { didSet { defaults.set(crossfadeSeconds, forKey: Keys.crossfade) } }
    /// On cellular, new songs stream as Plex's 192 kbps transcode instead of the original file.
    var dataSaver: Bool { didSet { defaults.set(dataSaver, forKey: Keys.dataSaver) } }

    private enum Keys {
        static let evenOutVolume = "settings.evenOutVolume"
        static let hemisphere = "settings.hemisphere"
        static let seasonalEffects = "settings.seasonalEffects"
        static let playInTheCar = "settings.playInTheCar"
        static let holidaysInSeason = "settings.holidaysInSeason"
        static let sectionID = "settings.sectionID"
        static let appIcon = "settings.appIcon"
        static let seasonalIcon = "settings.seasonalIcon"
        static let crossfade = "settings.crossfade"
        static let dataSaver = "settings.dataSaver"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        evenOutVolume = defaults.object(forKey: Keys.evenOutVolume) as? Bool ?? true
        hemisphere = defaults.string(forKey: Keys.hemisphere).flatMap(Hemisphere.init(rawValue:)) ?? .automatic
        seasonalEffects = defaults.object(forKey: Keys.seasonalEffects) as? Bool ?? true
        playInTheCar = Self.flag(Keys.playInTheCar, in: defaults, default: true)
        holidaysInSeason = Self.flag(Keys.holidaysInSeason, in: defaults, default: true)
        sectionID = defaults.string(forKey: Keys.sectionID)
        appIcon = defaults.string(forKey: Keys.appIcon).flatMap(AppIconChoice.init(rawValue:)) ?? .record
        seasonalIcon = defaults.object(forKey: Keys.seasonalIcon) as? Bool ?? true
        let fade = defaults.integer(forKey: Keys.crossfade)
        crossfadeSeconds = Crossfade.choices.contains(fade) ? fade : 0
        dataSaver = defaults.bool(forKey: Keys.dataSaver)
    }

    var isSouthern: Bool { hemisphere.isSouthern() }

    /// A launch argument (`-settings.holidaysInSeason NO`) arrives as the string "NO", which `as? Bool`
    /// doesn't see; `bool(forKey:)` reads it.
    private static func flag(_ key: String, in defaults: UserDefaults, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
