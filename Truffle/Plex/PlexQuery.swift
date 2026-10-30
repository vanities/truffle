import Foundation

/// A Plex query string, built by hand. Plex reads comparison filters off the parameter *name*
/// (`viewedAt>=…`, `userRating>>=8`), and it wants the `>` percent-encoded but the `=` literal:
/// on PMS 1.43 (2026-10-30) `viewedAt%3E=` worked, `viewedAt%3E%3D` was a 400, and a raw `>`
/// isn't legal in a URL at all. URLComponents' own encoding can't express that split.
struct PlexQuery: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let name: String
        let value: String
    }

    private(set) var items: [Item] = []

    init() {}

    init(_ pairs: [(String, String)]) {
        items = pairs.map { Item(name: $0.0, value: $0.1) }
    }

    func with(_ name: String, _ value: String) -> PlexQuery {
        var copy = self
        copy.items.append(Item(name: name, value: value))
        return copy
    }

    func with(_ name: String, _ value: Int) -> PlexQuery { with(name, String(value)) }

    /// The paging pair every list endpoint takes.
    func page(start: Int, size: Int) -> PlexQuery {
        with("X-Plex-Container-Start", start).with("X-Plex-Container-Size", size)
    }

    var isEmpty: Bool { items.isEmpty }

    var encoded: String {
        items.map { Self.escape($0.name) + "=" + Self.escape($0.value) }.joined(separator: "&")
    }

    /// Unreserved characters plus `,` (Plex's OR lists: `mood=1,2`) and `:` (`sort=addedAt:desc`).
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~,:")

    static func escape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
