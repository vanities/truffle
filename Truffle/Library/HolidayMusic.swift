import Foundation

/// Holiday music, found by title: a song counts when its own title or its album's has one of
/// `phrases`. Adam's library has no Christmas or Holiday genre or mood tags (checked 2026-10-30), so
/// titles are what there is. With "Keep Holidays in Season" on, Shuffle All and Album Roulette leave it
/// for the holidays.
enum HolidayMusic {
    /// Whole words and phrases, matched without case or accents ("Noël"); a trailing s doesn't matter
    /// ("Holidays", "Deck the Hall"), and "Santa's" splits into "santa" and "s".
    static let phrases = [
        "christmas", "christmastime", "xmas", "jingle", "santa", "navidad", "noel", "silent night", "sleigh",
        "mistletoe", "holiday", "merry", "deck the halls", "o holy night", "oh holy night", "frosty", "rudolph",
        "hark the herald", "joy to the world", "feliz",
    ]

    /// Titles that hold one of the words without being holiday music. They're taken out before matching,
    /// so "Santa Claus in Santa Monica" still counts.
    static let lookalikes = [
        "santa monica", "santa fe", "santa cruz", "santa barbara", "santa ana", "santa clara", "santa rosa",
        "santa maria", "merry go round", "jingle jangle", "feliz cumpleaños", "holiday in cambodia", "holiday road",
        "roman holiday", "billie holiday", "holidays in the sun",
    ]

    /// What to ask Plex for when counting. Its `title=` matches substrings, so one distinctive word per
    /// phrase finds the song even with punctuation between the words ("Hark! The Herald"). Plex may not
    /// fold accents, hence "noël" as well as "noel".
    static let searchTerms = [
        "christmas", "xmas", "jingle", "santa", "navidad", "noel", "noël", "silent", "sleigh", "mistletoe", "holiday",
        "merry", "deck", "holy", "frosty", "rudolph", "herald", "joy", "feliz",
    ]

    /// The day after Thanksgiving through January 2: the Holidays and New Year themes.
    static func isInSeason(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch SeasonCalendar.moment(for: date, calendar: calendar) {
        case .christmas, .newYear: true
        case .halloween, .thanksgiving, .valentines, .stPatricks, .fourthOfJuly, nil: false
        }
    }

    static func isHoliday(_ track: Track) -> Bool {
        matches(track.title) || matches(track.album)
    }

    static func matches(_ title: String) -> Bool {
        var titleWords = words(in: title)
        guard !titleWords.isEmpty else { return false }
        for lookalike in lookalikeWords {
            for start in occurrences(of: lookalike, in: titleWords) {
                titleWords.replaceSubrange(start..<(start + lookalike.count), with: repeatElement("", count: lookalike.count))
            }
        }
        return phraseWords.contains { !occurrences(of: $0, in: titleWords).isEmpty }
    }

    /// How many songs are holiday music: every song on an album titled for the holidays, plus the songs
    /// titled for them on other albums. `titled` is what a title search found (Plex's substring match
    /// finds more than this rule keeps).
    static func count(albums: [Album], titled: [Track]) -> Int {
        let holidayAlbums = albums.filter { matches($0.title) }
        let albumIDs = Set(holidayAlbums.map(\.id))
        let onHolidayAlbums = holidayAlbums.reduce(0) { $0 + ($1.trackCount ?? 0) }
        let elsewhere = Set(titled.filter { isHoliday($0) && !albumIDs.contains($0.albumID ?? "") }.map(\.id))
        return onHolidayAlbums + elsewhere.count
    }

    // MARK: - Words

    private static let phraseWords = phrases.map(words(in:))
    private static let lookalikeWords = lookalikes.map(words(in:))

    /// Lowercased, accents folded, split on anything that isn't a letter or a digit, one trailing s
    /// dropped (from words over three letters, so "is" and "us" stay put).
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : String($0) }
    }

    private static func occurrences(of phrase: [String], in words: [String]) -> [Int] {
        guard !phrase.isEmpty, phrase.count <= words.count else { return [] }
        return (0...(words.count - phrase.count)).filter { Array(words[$0..<($0 + phrase.count)]) == phrase }
    }
}

/// What the library knows about its holiday music, saved beside the shuffle walk
/// (`holidays-<section>.json`).
struct HolidayIndex: Codable, Sendable, Equatable {
    /// Holiday songs in the library, for Settings.
    var songs = 0
    /// The song count `songs` was counted at; a library that changed size gets counted again.
    var countedAt: Int?
    /// `sort=id` positions the shuffle found holding holiday music, so later draws step over them
    /// without asking the server again. New songs append, so these hold until the library shrinks.
    var positions: Set<Int32> = []

    func needsCount(trackCount: Int) -> Bool { trackCount > 0 && countedAt != trackCount }

    /// Songs went away, so the positions after them moved: find them again as the shuffle draws.
    mutating func libraryShrank() { positions = [] }
}
