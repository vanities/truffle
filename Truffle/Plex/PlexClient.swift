import Foundation
import os

enum PlexError: LocalizedError, Equatable {
    case http(status: Int, path: String)
    case unauthorized
    case decoding(path: String)
    case unreachable(server: String)
    case noServer
    case noMusicLibrary
    case signInExpired

    var errorDescription: String? {
        switch self {
        case .http(let status, _): "Plex answered with an error (\(status))."
        case .unauthorized: "Plex says this sign-in isn't valid anymore. Sign in again."
        case .decoding: "Plex sent something Truffle couldn't read."
        case .unreachable(let server): "\(server) isn't answering."
        case .noServer: "There's no Plex Media Server on this account."
        case .noMusicLibrary: "This server has no music library."
        case .signInExpired: "The sign-in code expired. Try again."
        }
    }
}

/// One way of reaching one server: its address, how it's reached, and the token it takes.
struct PlexEndpoint: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case local, remote, relay
    }

    let baseURL: URL
    let kind: Kind
    let machineIdentifier: String
    let token: String
}

/// Requests to a Plex Media Server. Logs carry the path, status, size and time; never the token
/// or a full URL (stream and artwork URLs embed the token, because AVPlayer can't send headers).
struct PlexClient: Sendable {
    let endpoint: PlexEndpoint
    let identity: PlexIdentity
    var session: URLSession = .shared
    var timeout: TimeInterval = 20

    func url(_ path: String, _ query: PlexQuery = PlexQuery(), includeToken: Bool = false) -> URL {
        let finalQuery = includeToken ? query.with("X-Plex-Token", endpoint.token) : query
        var base = endpoint.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let string = base + path + (finalQuery.isEmpty ? "" : "?" + finalQuery.encoded)
        return URL(string: string) ?? endpoint.baseURL
    }

    /// `body` goes out as is: a cover upload is the JPEG itself, not a form.
    func request(_ method: String, _ path: String, _ query: PlexQuery = PlexQuery(), body: Data? = nil,
                 contentType: String? = nil) -> URLRequest {
        var request = URLRequest(url: url(path, query), timeoutInterval: timeout)
        request.httpMethod = method
        for (name, value) in identity.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(endpoint.token, forHTTPHeaderField: "X-Plex-Token")
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func get(_ path: String, _ query: PlexQuery = PlexQuery()) async throws -> PlexContainer {
        try await container("GET", path, query)
    }

    /// Any request Plex answers with a MediaContainer (`POST /playlists` answers with the new playlist).
    func container(_ method: String, _ path: String, _ query: PlexQuery = PlexQuery()) async throws -> PlexContainer {
        let data = try await send(method, path, query)
        guard !data.isEmpty else { return .empty }
        do {
            return try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: data).container
        } catch {
            Logger.plex.error("[plex] decode failed for \(method, privacy: .public) \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw PlexError.decoding(path: path)
        }
    }

    @discardableResult
    func send(_ method: String, _ path: String, _ query: PlexQuery = PlexQuery(), body: Data? = nil,
              contentType: String? = nil) async throws -> Data {
        let sw = Stopwatch()
        let data: Data
        let response: URLResponse
        if let body {
            Logger.plex.debug("[plex] \(method, privacy: .public) \(path, privacy: .public) sending \(body.count)B \(contentType ?? "?", privacy: .public)")
        }
        do {
            (data, response) = try await session.data(for: request(method, path, query, body: body, contentType: contentType))
        } catch {
            Logger.plex.error("[plex] \(method, privacy: .public) \(path, privacy: .public) via \(endpoint.kind.rawValue, privacy: .public) failed after \(sw.ms, format: .fixed(precision: 0))ms: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Logger.plex.debug("[plex] \(method, privacy: .public) \(path, privacy: .public) → \(status) \(data.count)B in \(sw.ms, format: .fixed(precision: 0))ms")
        if status == 401 { throw PlexError.unauthorized }
        guard (200..<300).contains(status) else {
            Logger.plex.error("[plex] \(method, privacy: .public) \(path, privacy: .public) → \(status) query=\(query.items.map(\.name).joined(separator: ","), privacy: .public)")
            throw PlexError.http(status: status, path: path)
        }
        return data
    }

    /// Direct play: the original file, which AVPlayer streams with range requests (FLAC included).
    func streamURL(partKey: String) -> URL {
        url(partKey, includeToken: true)
    }

    /// Plex's own resizer: a 300 px cover is ~19 KB instead of the 135 KB original.
    func artworkURL(_ thumb: String, size: Int) -> URL {
        url("/photo/:/transcode", PlexQuery([
            ("width", String(size)), ("height", String(size)), ("minSize", "1"), ("upscale", "1"), ("url", thumb),
        ]), includeToken: true)
    }
}
