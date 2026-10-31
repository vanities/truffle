import Foundation

enum Hemisphere: String, Codable, CaseIterable, Sendable {
    case automatic, northern, southern

    /// Automatic goes by the time zone: close enough to put Sydney in summer at Christmas.
    func isSouthern(timeZone: TimeZone = .current) -> Bool {
        switch self {
        case .northern: return false
        case .southern: return true
        case .automatic:
            let id = timeZone.identifier
            return Self.southernZonePrefixes.contains { id.hasPrefix($0) }
        }
    }

    private static let southernZonePrefixes = [
        "Australia/", "Antarctica/", "Pacific/Auckland", "Pacific/Chatham", "Pacific/Fiji", "Pacific/Tongatapu",
        "America/Argentina", "America/Buenos_Aires", "America/Sao_Paulo", "America/Santiago", "America/Montevideo",
        "America/Asuncion", "America/La_Paz", "America/Lima", "Africa/Johannesburg", "Africa/Maputo", "Africa/Harare",
        "Africa/Windhoek", "Africa/Lusaka", "Indian/Mauritius", "Indian/Reunion",
    ]
}

enum Season: String, Codable, CaseIterable, Sendable {
    case winter, spring, summer, fall

    var title: String {
        switch self {
        case .winter: "Winter"
        case .spring: "Spring"
        case .summer: "Summer"
        case .fall: "Fall"
        }
    }

    /// The month (1–12) the season starts in. Meteorological seasons, whole months: how people
    /// talk about them, and simple to window history by.
    func startMonth(southern: Bool) -> Int {
        let north = switch self {
        case .winter: 12
        case .spring: 3
        case .summer: 6
        case .fall: 9
        }
        return southern ? (north + 5) % 12 + 1 : north
    }

    static func of(month: Int, southern: Bool) -> Season {
        let shifted = southern ? (month + 5) % 12 + 1 : month
        switch shifted {
        case 12, 1, 2: return .winter
        case 3, 4, 5: return .spring
        case 6, 7, 8: return .summer
        default: return .fall
        }
    }
}

/// A stretch of the year with its own look and mix, on top of the season.
enum Moment: String, Codable, CaseIterable, Sendable {
    case halloween, thanksgiving, christmas, newYear, valentines
}

struct RGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }
}

/// Which mood tags make a mix. Plex tags albums (and some songs) with AllMusic-style moods;
/// primary moods carry the mix and secondary ones fill it out.
struct MoodRecipe: Equatable, Sendable {
    let title: String
    let subtitle: String
    let symbol: String
    let primary: [String]
    let secondary: [String]

    static let nightDrive = MoodRecipe(title: "Night Drive", subtitle: "Headlights on", symbol: "moon.haze.fill",
                                       primary: ["Nocturnal"], secondary: ["Hypnotic", "Atmospheric", "Dreamy"])
}

/// Everything seasonal on screen right now: colors, particles, greeting, and the season's mix.
struct SeasonTheme: Equatable, Sendable {
    enum Particles: String, Sendable {
        case leaves, snow, petals, fireflies, embers, lights, confetti, hearts
    }

    let season: Season
    let moment: Moment?
    let title: String
    let greeting: String
    let particles: Particles
    /// Deep, middle and bright, for gradients.
    let palette: [RGB]
    let accent: RGB
    let recipe: MoodRecipe

    var id: String { moment?.rawValue ?? season.rawValue }
}

enum SeasonCalendar {
    /// Now, or the `-TruffleDate 2026-12-20T21:00` a debug build was launched with to preview another
    /// season. The shuffle reads it too, so holiday music follows the previewed date.
    static var now: Date {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "TruffleDate") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = text.contains("T") ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
            if let date = formatter.date(from: text) { return date }
        }
        #endif
        return .now
    }

    static func theme(for date: Date, southern: Bool, calendar: Calendar = .current) -> SeasonTheme {
        let season = Season.of(month: calendar.component(.month, from: date), southern: southern)
        if let moment = moment(for: date, calendar: calendar) {
            return theme(moment: moment, season: season)
        }
        return theme(season: season)
    }

    static func moment(for date: Date, calendar: Calendar = .current) -> Moment? {
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        switch (month, day) {
        case (10, 15...31): return .halloween
        case (12, 27...31), (1, 1): return .newYear
        case (2, 7...14): return .valentines
        case (12, 1...26): return .christmas
        case (11, _):
            // Thanksgiving week is the seven days ending on the day (US: the fourth Thursday); Christmas
            // music starts the day after.
            let year = calendar.component(.year, from: date)
            guard let thanksgiving = thanksgiving(year: year, calendar: calendar),
                  let weekBefore = calendar.date(byAdding: .day, value: -6, to: thanksgiving) else { return nil }
            let day = calendar.startOfDay(for: date)
            if day > thanksgiving { return .christmas }
            return day >= weekBefore ? .thanksgiving : nil
        default: return nil
        }
    }

    static func thanksgiving(year: Int, calendar: Calendar = .current) -> Date? {
        var components = DateComponents(year: year, month: 11, weekday: 5, weekdayOrdinal: 4)
        components.calendar = calendar
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    static func theme(season: Season) -> SeasonTheme {
        switch season {
        case .fall:
            SeasonTheme(season: .fall, moment: nil, title: "Fall", greeting: "Sweater weather", particles: .leaves,
                        palette: [RGB(0x3A1C12), RGB(0xB5532A), RGB(0xF2A541)], accent: RGB(0xE8762D),
                        recipe: MoodRecipe(title: "Fall Mix", subtitle: "Leaf peeping", symbol: "leaf.fill",
                                           primary: ["Autumnal"], secondary: ["Wistful", "Bittersweet", "Nostalgic", "Earthy"]))
        case .winter:
            SeasonTheme(season: .winter, moment: nil, title: "Winter", greeting: "Bundle up", particles: .snow,
                        palette: [RGB(0x0E1A33), RGB(0x2E5A8C), RGB(0xA9D2FF)], accent: RGB(0x4A9DEB),
                        recipe: MoodRecipe(title: "Winter Mix", subtitle: "Brr.", symbol: "snowflake",
                                           primary: ["Wintry", "Cold"], secondary: ["Ethereal", "Somber", "Calm/Peaceful", "Introspective"]))
        case .spring:
            SeasonTheme(season: .spring, moment: nil, title: "Spring", greeting: "Hello, pollen", particles: .petals,
                        palette: [RGB(0x1C2E1F), RGB(0x5E9A62), RGB(0xF6B8C8)], accent: RGB(0xD9577F),
                        recipe: MoodRecipe(title: "Spring Mix", subtitle: "Windows down", symbol: "camera.macro",
                                           primary: ["Springlike", "Pastoral"], secondary: ["Uplifting", "Cheerful", "Gentle", "Light"]))
        case .summer:
            SeasonTheme(season: .summer, moment: nil, title: "Summer", greeting: "SPF on", particles: .fireflies,
                        palette: [RGB(0x10233B), RGB(0x1F8A8A), RGB(0xFFD166)], accent: RGB(0xE8960C),
                        recipe: MoodRecipe(title: "Summer Mix", subtitle: "Sun's out", symbol: "sun.max.fill",
                                           primary: ["Summery"], secondary: ["Carefree", "Exuberant", "Playful", "Celebratory"]))
        }
    }

    static func theme(moment: Moment, season: Season) -> SeasonTheme {
        switch moment {
        case .halloween:
            SeasonTheme(season: season, moment: .halloween, title: "Halloween", greeting: "Spooky season", particles: .embers,
                        palette: [RGB(0x14091F), RGB(0x4B1D5E), RGB(0xFF7518)], accent: RGB(0xF2711C),
                        recipe: MoodRecipe(title: "Halloween Mix", subtitle: "Boo.", symbol: "moon.stars.fill",
                                           primary: ["Spooky", "Eerie"], secondary: ["Ominous", "Menacing", "Malevolent", "Dark"]))
        case .thanksgiving:
            SeasonTheme(season: season, moment: .thanksgiving, title: "Thanksgiving", greeting: "Pass the pie", particles: .leaves,
                        palette: [RGB(0x2B170D), RGB(0xA0522D), RGB(0xF2B661)], accent: RGB(0xD9772B),
                        recipe: MoodRecipe(title: "Thanksgiving Mix", subtitle: "Gobble gobble", symbol: "fork.knife",
                                           primary: ["Warm", "Autumnal"], secondary: ["Earthy", "Nostalgic", "Celebratory"]))
        case .christmas:
            SeasonTheme(season: season, moment: .christmas, title: "The Holidays", greeting: "Jingle all the way", particles: .lights,
                        palette: [RGB(0x0F2A1D), RGB(0x8E1B2B), RGB(0xF4D35E)], accent: RGB(0xD7263D),
                        recipe: MoodRecipe(title: "Holiday Mix", subtitle: "Cozy mode", symbol: "gift.fill",
                                           primary: ["Wintry"], secondary: ["Warm", "Sentimental", "Celebratory"]))
        case .newYear:
            SeasonTheme(season: season, moment: .newYear, title: "New Year", greeting: "Ring it in", particles: .confetti,
                        palette: [RGB(0x0B0B1A), RGB(0x2B2D6E), RGB(0xE8C547)], accent: RGB(0xD4A72C),
                        recipe: MoodRecipe(title: "New Year Mix", subtitle: "Confetti required", symbol: "sparkles",
                                           primary: ["Celebratory", "Euphoric"], secondary: ["Rousing", "Triumphant", "Exuberant"]))
        case .valentines:
            SeasonTheme(season: season, moment: .valentines, title: "Valentine's", greeting: "Be mine", particles: .hearts,
                        palette: [RGB(0x2A0A18), RGB(0x9E1F4F), RGB(0xFF8FAB)], accent: RGB(0xF0436A),
                        recipe: MoodRecipe(title: "Love Songs", subtitle: "Smooch-adjacent", symbol: "heart.fill",
                                           primary: ["Romantic"], secondary: ["Tender", "Sensual", "Passionate", "Intimate"]))
        }
    }

    /// "Good evening", for the home screen.
    static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 20 || hour < 5
    }
}
