import Foundation

/// A list's sort choices. The first case is the default, and each list remembers its choice in
/// UserDefaults under `defaultsKey` (`@AppStorage`). Lists Plex pages to us are sorted by Plex; lists
/// that are already fully loaded sort on the device.
protocol SortOrder: RawRepresentable, CaseIterable, Identifiable, Hashable, Sendable
where RawValue == String, AllCases == [Self] {
    static var defaultsKey: String { get }
    var label: String { get }
}

extension SortOrder {
    var id: String { rawValue }
    static var standard: Self { allCases[0] }
}

/// Liked is paged from Plex, so Plex sorts it.
enum LikedSort: String, SortOrder {
    case recentlyLiked, title, artist, album, recentlyAdded, mostPlayed

    static let defaultsKey = "sort.liked"

    var label: String {
        switch self {
        case .recentlyLiked: "Recently Liked"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .recentlyAdded: "Recently Added"
        case .mostPlayed: "Most Played"
        }
    }

    /// PMS's sort keys for songs; `artist.titleSort` is its "Album Artist" order.
    var plexSort: String {
        switch self {
        case .recentlyLiked: "lastRatedAt:desc"
        case .title: "titleSort"
        case .artist: "artist.titleSort"
        case .album: "album.titleSort"
        case .recentlyAdded: "addedAt:desc"
        case .mostPlayed: "viewCount:desc"
        }
    }
}

enum AlbumSort: String, SortOrder {
    case title, artist, year, recentlyAdded, recentlyPlayed

    static let defaultsKey = "sort.albums"

    var label: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .year: "Year"
        case .recentlyAdded: "Recently Added"
        case .recentlyPlayed: "Recently Played"
        }
    }

    /// `albums` arrive in Plex's title order, which `.title` keeps.
    func sorted(_ albums: [Album]) -> [Album] {
        switch self {
        case .title:
            albums
        case .artist:
            albums.stableSorted { a, b in
                SortText.compare(a.artist, b.artist) ?? Ordered.ascending(a.year, b.year) ?? SortText.isBefore(a.title, b.title)
            }
        case .year:
            albums.stableSorted { Ordered.descending($0.year, $1.year) ?? false }
        case .recentlyAdded:
            albums.stableSorted { Ordered.descending($0.addedAt, $1.addedAt) ?? false }
        case .recentlyPlayed:
            albums.stableSorted { Ordered.descending($0.lastViewedAt, $1.lastViewedAt) ?? false }
        }
    }
}

enum ArtistSort: String, SortOrder {
    case name, recentlyPlayed, mostPlayed

    static let defaultsKey = "sort.artists"

    var label: String {
        switch self {
        case .name: "Name"
        case .recentlyPlayed: "Recently Played"
        case .mostPlayed: "Most Played"
        }
    }

    /// `artists` arrive in Plex's name order (titleSort: "The Lumineers" under L), which `.name` keeps.
    func sorted(_ artists: [Artist]) -> [Artist] {
        switch self {
        case .name:
            artists
        case .recentlyPlayed:
            artists.stableSorted { Ordered.descending($0.lastViewedAt, $1.lastViewedAt) ?? false }
        case .mostPlayed:
            artists.stableSorted { Ordered.descending($0.viewCount, $1.viewCount) ?? false }
        }
    }
}

enum PlaylistSort: String, SortOrder {
    case title, recentlyUpdated, mostSongs

    static let defaultsKey = "sort.playlists"

    var label: String {
        switch self {
        case .title: "Title"
        case .recentlyUpdated: "Recently Updated"
        case .mostSongs: "Most Songs"
        }
    }

    func sorted(_ playlists: [Playlist]) -> [Playlist] {
        switch self {
        case .title:
            playlists.stableSorted { SortText.isBefore($0.title, $1.title) }
        case .recentlyUpdated:
            playlists.stableSorted { Ordered.descending($0.updatedAt, $1.updatedAt) ?? false }
        case .mostSongs:
            playlists.stableSorted { $0.trackCount > $1.trackCount }
        }
    }
}

/// Inside a playlist. Sorted on the device, once every song is loaded.
enum PlaylistSongSort: String, SortOrder {
    case playlistOrder, title, artist, album

    static let defaultsKey = "sort.playlistSongs"

    var label: String {
        switch self {
        case .playlistOrder: "Playlist Order"
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        }
    }

    func sorted(_ tracks: [Track]) -> [Track] {
        switch self {
        case .playlistOrder:
            tracks
        case .title:
            tracks.stableSorted { SortText.isBefore($0.title, $1.title) }
        case .artist:
            tracks.stableSorted { a, b in
                SortText.compare(a.artist, b.artist) ?? SortText.compare(a.album, b.album) ?? Self.albumOrder(a, b)
            }
        case .album:
            tracks.stableSorted { a, b in SortText.compare(a.album, b.album) ?? Self.albumOrder(a, b) }
        }
    }

    private static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        Ordered.ascending(a.discNumber, b.discNumber) ?? Ordered.ascending(a.trackNumber, b.trackNumber) ?? false
    }
}

// MARK: - Helpers

/// Text order the way Plex's titleSort reads names: case and accents aside, numbers by value, and a
/// leading "The " skipped.
enum SortText {
    static func key(_ text: String) -> String {
        text.hasPrefix("The ") ? String(text.dropFirst(4)) : text
    }

    /// nil when the two read the same, so the caller can break the tie.
    static func compare(_ a: String, _ b: String) -> Bool? {
        switch key(a).localizedStandardCompare(key(b)) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: nil
        }
    }

    static func isBefore(_ a: String, _ b: String) -> Bool { compare(a, b) ?? false }
}

/// Optional values compared with the missing ones last, whichever the direction. nil on a tie.
enum Ordered {
    static func ascending<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
        switch (a, b) {
        case let (a?, b?): a == b ? nil : a < b
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): nil
        }
    }

    static func descending<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
        switch (a, b) {
        case let (a?, b?): a == b ? nil : a > b
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): nil
        }
    }
}

extension Array {
    /// Ties keep the order they came in.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if areInIncreasingOrder(a.element, b.element) { return true }
            if areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
