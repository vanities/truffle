import Foundation
import os

extension MusicLibrary {
    private var holidaysName: String { "holidays-\(section?.id ?? "none").json" }

    func loadHolidays() {
        holidays = store.load(HolidayIndex.self, from: holidaysName) ?? HolidayIndex()
        Logger.shuffle.debug("[holidays] loaded: \(self.holidays.songs) songs counted at \(self.holidays.countedAt ?? 0), \(self.holidays.positions.count) positions known")
    }

    func saveHolidays() {
        store.save(holidays, to: holidaysName)
    }

    /// Whether Shuffle All and Album Roulette leave holiday music out right now.
    func holdsBackHolidayMusic(now: Date) -> Bool {
        settings.holidaysInSeason && !HolidayMusic.isInSeason(now)
    }

    /// How many songs are holiday music, for Settings. One `title=` search per word (Plex matches
    /// substrings), narrowed by `HolidayMusic`'s whole-word rule, plus the songs on albums titled for the
    /// holidays, from the album list the library already has. Runs when the song count changes; the
    /// answer is saved with the shuffle's holiday positions.
    func countHolidaySongs() async {
        guard let section, holidays.needsCount(trackCount: trackCount) else { return }
        let sw = Stopwatch()
        let counting = trackCount
        let path = "/library/sections/\(section.id)/all"
        do {
            let titled = try await withClient("holiday titles") { client in
                try await withThrowingTaskGroup(of: [Track].self) { group in
                    for term in HolidayMusic.searchTerms {
                        group.addTask {
                            try await client.get(path, PlexQuery([("type", "10"), ("title", term)]).page(start: 0, size: 500))
                                .metadata.compactMap(Track.init)
                        }
                    }
                    var found: [Track] = []
                    for try await tracks in group { found += tracks }
                    return found
                }
            }
            let songs = HolidayMusic.count(albums: albums, titled: titled)
            guard trackCount == counting else {
                Logger.shuffle.info("[holidays] library changed while counting (\(counting) → \(self.trackCount)); counting again next refresh")
                return
            }
            holidays.songs = songs
            holidays.countedAt = counting
            saveHolidays()
            let holidayAlbums = albums.filter { HolidayMusic.matches($0.title) }.count
            Logger.shuffle.info("[holidays] \(songs) holiday songs of \(counting) (\(holidayAlbums) holiday album(s), \(titled.count) title hits from \(HolidayMusic.searchTerms.count) searches) in \(sw.ms, format: .fixed(precision: 0))ms")
        } catch {
            Logger.shuffle.error("[holidays] count failed after \(sw.ms, format: .fixed(precision: 0))ms: \(error.localizedDescription, privacy: .public)")
        }
    }
}
