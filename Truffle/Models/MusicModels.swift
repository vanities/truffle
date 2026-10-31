import Foundation

/// A song. Built from Plex's metadata; Codable so the queue and the library cache survive launches.
struct Track: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var albumID: String?
    var artistID: String?
    var trackNumber: Int?
    var discNumber: Int?
    var duration: TimeInterval
    var thumb: String?
    var partKey: String?
    var codec: String?
    var userRating: Double?
    var year: Int?
    /// From the server's loudness analysis; only `/library/metadata/{id}` includes it.
    var loudness: Double?
    var gain: Double?
    var albumGain: Double?

    /// Plex ratings run 0–10; Plexamp's love is a 10, and four stars counts too.
    var isLiked: Bool { (userRating ?? 0) >= 8 }
    var hasLoudness: Bool { loudness != nil }

    init(id: String, title: String, artist: String, album: String, albumID: String? = nil, artistID: String? = nil,
         trackNumber: Int? = nil, discNumber: Int? = nil, duration: TimeInterval = 0, thumb: String? = nil,
         partKey: String? = nil, codec: String? = nil, userRating: Double? = nil, year: Int? = nil,
         loudness: Double? = nil, gain: Double? = nil, albumGain: Double? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumID = albumID
        self.artistID = artistID
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.thumb = thumb
        self.partKey = partKey
        self.codec = codec
        self.userRating = userRating
        self.year = year
        self.loudness = loudness
        self.gain = gain
        self.albumGain = albumGain
    }

    init?(_ metadata: PlexMetadata) {
        guard !metadata.ratingKey.isEmpty, metadata.type == nil || metadata.type == "track" else { return nil }
        let media = metadata.media.first
        let part = media?.parts.first
        let stream = part?.streams.first { $0.streamType == 2 } ?? part?.streams.first
        self.init(
            id: metadata.ratingKey,
            title: metadata.title ?? "Untitled",
            // A compilation's track carries its own artist in originalTitle.
            artist: metadata.originalTitle ?? metadata.grandparentTitle ?? "Unknown Artist",
            album: metadata.parentTitle ?? "",
            albumID: metadata.parentRatingKey,
            artistID: metadata.grandparentRatingKey,
            trackNumber: metadata.index,
            discNumber: metadata.parentIndex,
            duration: TimeInterval(metadata.duration ?? 0) / 1000,
            thumb: metadata.parentThumb ?? metadata.thumb ?? metadata.grandparentThumb,
            partKey: part?.key,
            codec: media?.audioCodec ?? part?.container,
            userRating: metadata.userRating,
            year: metadata.parentYear ?? metadata.year,
            loudness: stream?.loudness,
            gain: stream?.gain,
            albumGain: stream?.albumGain
        )
    }

    /// Keeps what the list endpoints don't send (loudness) when a later copy of the same song arrives.
    func merging(details: Track) -> Track {
        var merged = details
        if merged.loudness == nil { merged.loudness = loudness }
        if merged.gain == nil { merged.gain = gain }
        if merged.albumGain == nil { merged.albumGain = albumGain }
        return merged
    }
}

struct Album: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var artist: String
    var artistID: String?
    var year: Int?
    var thumb: String?
    var trackCount: Int?
    var addedAt: Date?

    init(id: String, title: String, artist: String, artistID: String? = nil, year: Int? = nil, thumb: String? = nil,
         trackCount: Int? = nil, addedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistID = artistID
        self.year = year
        self.thumb = thumb
        self.trackCount = trackCount
        self.addedAt = addedAt
    }

    init?(_ metadata: PlexMetadata) {
        guard !metadata.ratingKey.isEmpty, metadata.type == nil || metadata.type == "album" else { return nil }
        self.init(id: metadata.ratingKey, title: metadata.title ?? "Untitled", artist: metadata.parentTitle ?? "Unknown Artist",
                  artistID: metadata.parentRatingKey, year: metadata.year, thumb: metadata.thumb,
                  trackCount: metadata.leafCount, addedAt: metadata.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

struct Artist: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var thumb: String?
    var albumCount: Int?

    init(id: String, title: String, thumb: String? = nil, albumCount: Int? = nil) {
        self.id = id
        self.title = title
        self.thumb = thumb
        self.albumCount = albumCount
    }

    init?(_ metadata: PlexMetadata) {
        guard !metadata.ratingKey.isEmpty, metadata.type == nil || metadata.type == "artist" else { return nil }
        self.init(id: metadata.ratingKey, title: metadata.title ?? "Unknown Artist", thumb: metadata.thumb,
                  albumCount: metadata.childCount)
    }
}

struct Playlist: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var isSmart: Bool
    var trackCount: Int
    var duration: TimeInterval
    var thumb: String?
    var summary: String?

    init(id: String, title: String, isSmart: Bool, trackCount: Int, duration: TimeInterval = 0, thumb: String? = nil,
         summary: String? = nil) {
        self.id = id
        self.title = title
        self.isSmart = isSmart
        self.trackCount = trackCount
        self.duration = duration
        self.thumb = thumb
        self.summary = summary
    }

    init?(_ metadata: PlexMetadata) {
        guard !metadata.ratingKey.isEmpty else { return nil }
        // A playlist only has `thumb` once someone gives it a poster; otherwise Plex's collage.
        self.init(id: metadata.ratingKey, title: metadata.title ?? "Playlist", isSmart: metadata.smart ?? false,
                  trackCount: metadata.leafCount ?? 0, duration: TimeInterval(metadata.duration ?? 0) / 1000,
                  thumb: metadata.thumb ?? metadata.composite, summary: metadata.summary)
    }

    /// A seasonal mix made by the seasonal-mix skill: its summary ends with `truffle-mix:<theme>:<year>`.
    var mixTag: (theme: String, year: Int)? {
        guard let tag = summary?.split(separator: " ").last(where: { $0.hasPrefix("truffle-mix:") }) else { return nil }
        let parts = tag.split(separator: ":")
        guard parts.count == 3, let year = Int(parts[2]) else { return nil }
        return (String(parts[1]), year)
    }

    /// The summary without the tag: the mix's one-liner.
    var blurb: String? {
        guard let summary else { return nil }
        let words = summary.split(separator: " ").filter { !$0.hasPrefix("truffle-mix:") }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Big smart playlists ("All Music") shuffle by walking random positions instead of
    /// downloading every item first.
    var isLarge: Bool { trackCount > 1000 }
}
