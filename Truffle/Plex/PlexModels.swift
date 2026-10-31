import Foundation

// Decodable shapes of what Plex sends. Only the fields Truffle uses; everything optional, because
// Plex omits whatever doesn't apply, and some numbers arrive as strings (`"gain": "-11.79"`, and
// history's `"librarySectionID": "3"`), hence the `flexible…` readers.

/// Every server answer is `{"MediaContainer": {...}}`.
struct PlexEnvelope<Body: Decodable & Sendable>: Decodable, Sendable {
    let container: Body

    enum CodingKeys: String, CodingKey {
        case container = "MediaContainer"
    }
}

struct PlexContainer: Decodable, Sendable {
    var size: Int?
    var totalSize: Int?
    var offset: Int?
    var machineIdentifier: String?
    var friendlyName: String?
    var metadata: [PlexMetadata] = []
    var directories: [PlexDirectory] = []
    var hubs: [PlexHub] = []

    static let empty = PlexContainer()

    private init() {}

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, machineIdentifier, friendlyName
        case metadata = "Metadata", directories = "Directory", hubs = "Hub"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.flexibleInt(.size)
        totalSize = c.flexibleInt(.totalSize)
        offset = c.flexibleInt(.offset)
        machineIdentifier = c.flexibleString(.machineIdentifier)
        friendlyName = c.flexibleString(.friendlyName)
        metadata = c.lossyArray(PlexMetadata.self, .metadata)
        directories = c.lossyArray(PlexDirectory.self, .directories)
        hubs = c.lossyArray(PlexHub.self, .hubs)
    }
}

/// One item: a track, album, artist, playlist, or a history entry.
struct PlexMetadata: Decodable, Sendable, Hashable {
    var ratingKey = ""
    var key: String?
    var type: String?
    var title: String?
    var originalTitle: String?
    var parentTitle: String?
    var grandparentTitle: String?
    var parentRatingKey: String?
    var grandparentRatingKey: String?
    var index: Int?
    var parentIndex: Int?
    var year: Int?
    var parentYear: Int?
    var duration: Int?
    var thumb: String?
    var parentThumb: String?
    var grandparentThumb: String?
    var composite: String?
    var leafCount: Int?
    var childCount: Int?
    var viewCount: Int?
    var userRating: Double?
    var addedAt: Int?
    var lastViewedAt: Int?
    var viewedAt: Int?
    var updatedAt: Int?
    var smart: Bool?
    var playlistItemID: Int?
    var librarySectionID: String?
    var summary: String?
    var media: [PlexMedia] = []
    var moods: [String] = []
    var genres: [String] = []

    init(ratingKey: String, type: String? = nil, title: String? = nil) {
        self.ratingKey = ratingKey
        self.type = type
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, originalTitle, parentTitle, grandparentTitle, parentRatingKey,
             grandparentRatingKey, index, parentIndex, year, parentYear, duration, thumb, parentThumb,
             grandparentThumb, composite, leafCount, childCount, viewCount, userRating, addedAt,
             lastViewedAt, viewedAt, updatedAt, smart, playlistItemID, librarySectionID, summary
        case media = "Media", mood = "Mood", genre = "Genre"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = c.flexibleString(.ratingKey) ?? ""
        key = c.flexibleString(.key)
        type = c.flexibleString(.type)
        title = c.flexibleString(.title)
        originalTitle = c.flexibleString(.originalTitle)
        parentTitle = c.flexibleString(.parentTitle)
        grandparentTitle = c.flexibleString(.grandparentTitle)
        parentRatingKey = c.flexibleString(.parentRatingKey)
        grandparentRatingKey = c.flexibleString(.grandparentRatingKey)
        index = c.flexibleInt(.index)
        parentIndex = c.flexibleInt(.parentIndex)
        year = c.flexibleInt(.year)
        parentYear = c.flexibleInt(.parentYear)
        duration = c.flexibleInt(.duration)
        thumb = c.flexibleString(.thumb)
        parentThumb = c.flexibleString(.parentThumb)
        grandparentThumb = c.flexibleString(.grandparentThumb)
        composite = c.flexibleString(.composite)
        leafCount = c.flexibleInt(.leafCount)
        childCount = c.flexibleInt(.childCount)
        viewCount = c.flexibleInt(.viewCount)
        userRating = c.flexibleDouble(.userRating)
        addedAt = c.flexibleInt(.addedAt)
        lastViewedAt = c.flexibleInt(.lastViewedAt)
        viewedAt = c.flexibleInt(.viewedAt)
        updatedAt = c.flexibleInt(.updatedAt)
        smart = c.flexibleBool(.smart)
        playlistItemID = c.flexibleInt(.playlistItemID)
        librarySectionID = c.flexibleString(.librarySectionID)
        summary = c.flexibleString(.summary)
        media = c.lossyArray(PlexMedia.self, .media)
        moods = c.lossyArray(PlexTag.self, .mood).map(\.tag)
        genres = c.lossyArray(PlexTag.self, .genre).map(\.tag)
    }
}

struct PlexMedia: Decodable, Sendable, Hashable {
    var container: String?
    var audioCodec: String?
    var bitrate: Int?
    var parts: [PlexPart] = []

    enum CodingKeys: String, CodingKey {
        case container, audioCodec, bitrate
        case parts = "Part"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        container = c.flexibleString(.container)
        audioCodec = c.flexibleString(.audioCodec)
        bitrate = c.flexibleInt(.bitrate)
        parts = c.lossyArray(PlexPart.self, .parts)
    }
}

struct PlexPart: Decodable, Sendable, Hashable {
    var key: String?
    var container: String?
    var size: Int?
    var streams: [PlexStream] = []

    enum CodingKeys: String, CodingKey {
        case key, container, size
        case streams = "Stream"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.flexibleString(.key)
        container = c.flexibleString(.container)
        size = c.flexibleInt(.size)
        streams = c.lossyArray(PlexStream.self, .streams)
    }
}

/// An audio stream carries the server's loudness analysis (only on `/library/metadata/{id}`;
/// list endpoints leave streams out).
struct PlexStream: Decodable, Sendable, Hashable {
    var streamType: Int?
    var gain: Double?
    var albumGain: Double?
    var peak: Double?
    var loudness: Double?

    enum CodingKeys: String, CodingKey {
        case streamType, gain, albumGain, peak, loudness
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamType = c.flexibleInt(.streamType)
        gain = c.flexibleDouble(.gain)
        albumGain = c.flexibleDouble(.albumGain)
        peak = c.flexibleDouble(.peak)
        loudness = c.flexibleDouble(.loudness)
    }
}

struct PlexTag: Decodable, Sendable, Hashable {
    var tag: String
}

/// A library section, or one tag in a tag list (`/library/sections/3/mood` → key + title).
struct PlexDirectory: Decodable, Sendable, Hashable {
    var key: String
    var title: String
    var type: String?
    var agent: String?

    enum CodingKeys: String, CodingKey {
        case key, title, type, agent
    }

    init(key: String, title: String, type: String? = nil) {
        self.key = key
        self.title = title
        self.type = type
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.flexibleString(.key) ?? ""
        title = c.flexibleString(.title) ?? ""
        type = c.flexibleString(.type)
        agent = c.flexibleString(.agent)
    }
}

struct PlexHub: Decodable, Sendable {
    var type: String
    var metadata: [PlexMetadata] = []

    enum CodingKeys: String, CodingKey {
        case type
        case metadata = "Metadata"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.flexibleString(.type) ?? ""
        metadata = c.lossyArray(PlexMetadata.self, .metadata)
    }
}

// MARK: - plex.tv

struct PlexPin: Decodable, Sendable, Equatable {
    var id: Int
    var code: String
    var authToken: String?
    var expiresIn: Int?
}

struct PlexUser: Decodable, Sendable {
    var username: String?
    var title: String?
    var thumb: String?
}

struct PlexResource: Decodable, Sendable {
    var name: String
    var provides: String
    var clientIdentifier: String
    var owned: Bool?
    var accessToken: String?
    var connections: [PlexConnection]

    enum CodingKeys: String, CodingKey {
        case name, provides, clientIdentifier, owned, accessToken, connections
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexibleString(.name) ?? "Plex Media Server"
        provides = c.flexibleString(.provides) ?? ""
        clientIdentifier = c.flexibleString(.clientIdentifier) ?? ""
        owned = c.flexibleBool(.owned)
        accessToken = c.flexibleString(.accessToken)
        connections = c.lossyArray(PlexConnection.self, .connections)
    }

    var isServer: Bool { provides.split(separator: ",").contains("server") }
}

struct PlexConnection: Decodable, Sendable, Hashable {
    var uri: String
    var address: String?
    var port: Int?
    var local: Bool
    var relay: Bool

    enum CodingKeys: String, CodingKey {
        case uri, address, port, local, relay
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uri = c.flexibleString(.uri) ?? ""
        address = c.flexibleString(.address)
        port = c.flexibleInt(.port)
        local = c.flexibleBool(.local) ?? false
        relay = c.flexibleBool(.relay) ?? false
    }
}

// MARK: - Lenient readers

extension KeyedDecodingContainer {
    func flexibleString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func flexibleInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) ?? Double(value).map(Int.init) }
        return nil
    }

    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func flexibleBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value == "1" || value == "true" }
        return nil
    }

    /// An array where one odd element is dropped instead of failing the whole response.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard let elements = try? decodeIfPresent([Lossy<T>].self, forKey: key) else { return [] }
        return elements.compactMap(\.value)
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
