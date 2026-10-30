import Foundation
import os

/// plex.tv: sign-in PINs, the account, and the servers on it.
///
/// Sign-in is Plex's PIN flow: make a PIN, open app.plex.tv/auth with its code, and poll the PIN
/// until Plex attaches a token to it. Truffle never sees the password.
struct PlexAccountClient: Sendable {
    let identity: PlexIdentity
    var session: URLSession = .shared

    private static let api = "https://plex.tv/api/v2"

    func createPin() async throws -> PlexPin {
        try await fetch(PlexPin.self, "POST", "/pins", PlexQuery([("strong", "true")]))
    }

    func pin(_ id: Int) async throws -> PlexPin {
        try await fetch(PlexPin.self, "GET", "/pins/\(id)")
    }

    /// The page the user signs in on. `forwardURL` sends the browser back to Truffle afterwards.
    func authURL(code: String, forwardURL: String?) -> URL? {
        var query = PlexQuery([
            ("clientID", identity.clientIdentifier),
            ("code", code),
            ("context[device][product]", PlexIdentity.product),
        ])
        if let forwardURL { query = query.with("forwardUrl", forwardURL) }
        return URL(string: "https://app.plex.tv/auth#?" + query.encoded)
    }

    func user(token: String) async throws -> PlexUser {
        try await fetch(PlexUser.self, "GET", "/user", token: token)
    }

    /// Servers on the account, with every address plex.tv knows for each (home network, public, relay).
    func servers(token: String) async throws -> [PlexResource] {
        let query = PlexQuery([("includeHttps", "1"), ("includeRelay", "1"), ("includeIPv6", "1")])
        let resources = try await fetch([PlexResource].self, "GET", "/resources", query, token: token)
        let servers = resources.filter(\.isServer)
        Logger.auth.info("[account] \(resources.count) resource(s), \(servers.count) server(s): \(servers.map(\.name).joined(separator: ", "), privacy: .public)")
        return servers
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, _ query: PlexQuery = PlexQuery(),
                                     token: String? = nil) async throws -> T {
        guard let url = URL(string: Self.api + path + (query.isEmpty ? "" : "?" + query.encoded)) else {
            throw PlexError.http(status: 0, path: path)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        for (name, value) in identity.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }

        let sw = Stopwatch()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Logger.auth.debug("[account] \(method, privacy: .public) \(path, privacy: .public) → \(status) \(data.count)B in \(sw.ms, format: .fixed(precision: 0))ms")
        if status == 401 { throw PlexError.unauthorized }
        guard (200..<300).contains(status) else { throw PlexError.http(status: status, path: path) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Logger.auth.error("[account] decode failed for \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw PlexError.decoding(path: path)
        }
    }
}
