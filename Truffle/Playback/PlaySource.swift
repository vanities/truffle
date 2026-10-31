import Foundation

/// What's playing, as the user picked it.
struct PlaySource: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case album, artist, playlist, mix, shuffleAll, liked, search, songs
    }

    var kind: Kind
    var title: String
    var id: String?
    /// An album played front to back keeps the album's own loudness (see `Loudness`).
    var albumInOrder = false
    /// Played in a random order. A shuffled playlist crossfades like Shuffle All (see `Crossfade`).
    var shuffled = false

    static let shuffleAll = PlaySource(kind: .shuffleAll, title: "Shuffle All")

    enum CodingKeys: String, CodingKey {
        case kind, title, id, albumInOrder, shuffled
    }
}

extension PlaySource {
    /// Queues saved before a flag existed still restore.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        albumInOrder = try container.decodeIfPresent(Bool.self, forKey: .albumInOrder) ?? false
        shuffled = try container.decodeIfPresent(Bool.self, forKey: .shuffled) ?? false
    }
}

/// The queue saved between launches, so the car's play button picks up where you left off.
struct PlayerState: Codable, Sendable {
    var queue: PlayQueue
    var time: TimeInterval
    var source: PlaySource?
    var feed: ShuffleFeed?
    var savedAt: Date
}
