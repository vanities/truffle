import Foundation
import Network
import os

/// "Take it for a spin": serves `DemoLibrary` on 127.0.0.1 and answers Truffle's requests the way
/// Plex Media Server does, so the demo runs the real app (lists, artwork, streaming, CarPlay) with no
/// account. Built for App Review, which has no Plex server to sign in to. A port of the handler in
/// scripts/demo_server.py; keep the two in step. Loopback only, so nothing else on the network can
/// reach it and iOS asks for no permission.
actor DemoServer {
    static let shared = DemoServer()

    private let assets: URL?
    private let catalog: URL?
    private let queue = DispatchQueue(label: "com.vanities.truffle.demo-server")
    private var library: DemoLibrary?
    private var listener: NWListener?
    private var port: UInt16?
    private var listening = false

    init(assets: URL? = Bundle.main.url(forResource: "DemoLibrary", withExtension: nil),
         catalog: URL? = Bundle.main.url(forResource: "demo-catalog", withExtension: "json")) {
        self.assets = assets
        self.catalog = catalog
    }

    /// The server's address. Starts it, or restarts it after iOS closed the socket while the app was
    /// suspended, on the same port when it's free so queued songs keep their URLs.
    func start() async throws -> URL {
        if library == nil {
            guard let catalog, assets != nil else { throw DemoError.missingAssets }
            let sw = Stopwatch()
            let made = try DemoLibrary(catalogURL: catalog)
            library = made
            Logger.demo.info("[demo] library: \(made.artists.count) artists, \(made.albums.count) albums, \(made.tracks.count) songs, \(made.history.count) plays in \(sw.ms, format: .fixed(precision: 1))ms")
        }
        if listening, let port { return Self.url(port) }
        listener?.cancel()
        let sw = Stopwatch()
        let bound: UInt16
        do {
            bound = try await bind(port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        } catch where port != nil {
            Logger.demo.info("[demo] port \(self.port ?? 0) is taken, picking another")
            bound = try await bind(.any)
        }
        port = bound
        Logger.demo.info("[demo] listening on 127.0.0.1:\(bound) in \(sw.ms, format: .fixed(precision: 1))ms")
        return Self.url(bound)
    }

    /// Signing out of the demo forgets it, playlists and likes included.
    func stop() {
        listener?.cancel()
        listener = nil
        listening = false
        port = nil
        library = nil
        Logger.demo.info("[demo] stopped")
    }

    private static func url(_ port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    // MARK: - Listening

    private func bind(_ port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.serve(connection) }
        }
        let settled = OSAllocatedUnfairLock(initialState: false)
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                let first = settled.withLock { done in
                    defer { done = true }
                    return !done
                }
                switch state {
                case .ready where first:
                    continuation.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    if first { continuation.resume(throwing: error) } else { Task { await self?.lost(error) } }
                case .cancelled where first:
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        listening = true
        return bound
    }

    private func lost(_ error: NWError) {
        Logger.demo.info("[demo] listener closed (\(error.localizedDescription, privacy: .public)); restarts on the next connect")
        listening = false
    }

    // MARK: - Serving

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: queue)
        let sw = Stopwatch()
        do {
            let request = try await Self.read(connection)
            let response = respond(to: request)
            await Self.write(response.encoded(), to: connection)
            Logger.demo.debug("[demo] \(request.method, privacy: .public) \(request.path, privacy: .public) \(request.query.keys.sorted().joined(separator: ","), privacy: .public) → \(response.status) in \(sw.ms, format: .fixed(precision: 1))ms")
        } catch {
            Logger.demo.debug("[demo] connection dropped: \(error.localizedDescription, privacy: .public)")
        }
        connection.cancel()
    }

    private static func read(_ connection: NWConnection) async throws -> DemoRequest {
        var buffer = Data()
        let blankLine = Data("\r\n\r\n".utf8)
        while true {
            if let end = buffer.range(of: blankLine) {
                let request = try DemoRequest(head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
                // Truffle sends its parameters in the query; drain any body so the client isn't cut off mid-send.
                var bodyBytes = buffer.count - end.upperBound
                let expected = Int(request.headers["content-length"] ?? "") ?? 0
                while bodyBytes < expected, let more = try await receive(connection) { bodyBytes += more.count }
                return request
            }
            guard let chunk = try await receive(connection) else { throw DemoError.closed }
            buffer.append(chunk)
            if buffer.count > 64 * 1024 { throw DemoError.badRequest }
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    private static func write(_ data: Data, to connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    // MARK: - Routes

    private func respond(to request: DemoRequest) -> DemoResponse {
        guard let lib = library else { return .empty(503) }
        let path = request.path
        let query = request.query
        let stamp = DemoLibrary.stamp

        if path == "/identity" {
            return .json(Self.container(extra: ["machineIdentifier": DemoLibrary.machineIdentifier, "version": "1.43.5.truffle-demo"]))
        }
        if path == "/library/sections" {
            return .json(Self.container(directories: [["key": DemoLibrary.section, "type": "artist", "title": "Music",
                                                       "agent": "tv.plex.agents.music"]]))
        }
        if path.wholeMatch(of: #/\/library\/sections\/\d+\/mood/#) != nil {
            let moods = lib.moods.sorted { $0.name < $1.name }.map { mood -> [String: Any] in
                ["key": mood.key, "title": mood.name, "fastKey": "/library/sections/\(DemoLibrary.section)/all?mood=\(mood.key)"]
            }
            return .json(Self.container(directories: moods))
        }
        if path.wholeMatch(of: #/\/library\/sections\/\d+\/all/#) != nil {
            return .json(libraryAll(query, in: lib))
        }
        if let match = path.wholeMatch(of: #/\/library\/metadata\/(\d+)\/thumb\/\d+/#) {
            return file(lib.artwork(for: String(match.1)), type: "image/jpeg", request: request)
        }
        if let match = path.wholeMatch(of: #/\/library\/metadata\/(\d+)\/children/#) {
            let id = String(match.1)
            let kids: [[String: Any]] = lib.artist(id) != nil
                ? lib.albums.filter { $0.artistID == id }.map(lib.json)
                : lib.tracks.filter { $0.albumID == id }.map { lib.json($0) }
            return .json(Self.container(items: kids, total: kids.count))
        }
        if let match = path.wholeMatch(of: #/\/library\/metadata\/(\d+)\/allLeaves/#) {
            let id = String(match.1)
            let (chosen, total) = Self.page(lib.tracks.filter { $0.artistID == id }.map { lib.json($0) }, query)
            return .json(Self.container(items: chosen, total: total))
        }
        if let match = path.wholeMatch(of: #/\/library\/metadata\/([\d,]+)/#) {
            let items: [[String: Any]] = match.1.split(separator: ",").compactMap { part in
                let id = String(part)
                if let track = lib.track(id) { return lib.json(track, detailed: true) }
                if let album = lib.album(id) { return lib.json(album) }
                return lib.artist(id).map(lib.json)
            }
            return .json(Self.container(items: items))
        }
        if path == "/photo/:/transcode" {
            let thumb = query["url"] ?? ""
            if let match = thumb.wholeMatch(of: #/\/playlists\/(\d+)\/composite\/\d+/#) {
                let playlist = lib.playlists.first { $0.id == String(match.1) }
                let first = playlist.flatMap { lib.playlistTracks($0).first }
                return file(first.flatMap { lib.album($0.albumID)?.cover }, type: "image/jpeg", request: request)
            }
            if let match = thumb.wholeMatch(of: #/\/library\/metadata\/(\d+)\/thumb\/\d+/#) {
                return file(lib.artwork(for: String(match.1)), type: "image/jpeg", request: request)
            }
            return .empty(404)
        }
        if let match = path.wholeMatch(of: #/\/library\/parts\/(\d+)\/\d+\/file\.m4a/#) {
            return file(lib.track(String(match.1)).map { "audio/song-\($0.song).m4a" }, type: "audio/mp4", request: request)
        }
        if path == "/playlists", request.method == "GET" {
            return .json(Self.container(items: lib.playlists.map(lib.json)))
        }
        if path == "/playlists", request.method == "POST" {
            let made = DemoLibrary.Playlist(id: String(950 + lib.playlists.count), title: query["title"] ?? "Playlist", smart: false,
                                            items: Self.metadataIDs(in: query["uri"]))
            library?.playlists.append(made)
            return .json(Self.container(items: [(library ?? lib).json(made)]))
        }
        if let match = path.wholeMatch(of: #/\/playlists\/(\d+)\/items/#) {
            guard let position = lib.playlists.firstIndex(where: { $0.id == String(match.1) }) else { return .empty(404) }
            if request.method == "PUT" {
                library?.playlists[position].items = (lib.playlists[position].items ?? []) + Self.metadataIDs(in: query["uri"])
                let updated = library ?? lib
                return .json(Self.container(items: [updated.json(updated.playlists[position])]))
            }
            let items = lib.playlistTracks(lib.playlists[position]).enumerated().map { offset, track -> [String: Any] in
                var item = lib.json(track)
                item["playlistItemID"] = offset + 1
                return item
            }
            let (chosen, total) = Self.page(items, query)
            return .json(Self.container(items: chosen, total: total))
        }
        if path == "/hubs/search" {
            let text = (query["query"] ?? "").lowercased()
            let limit = Int(query["limit"] ?? "") ?? 10
            let hubs: [[String: Any]] = [
                ["type": "artist", "Metadata": Array(lib.artists.filter { $0.name.lowercased().contains(text) }.prefix(limit).map(lib.json))],
                ["type": "album", "Metadata": Array(lib.albums.filter { $0.title.lowercased().contains(text) }.prefix(limit).map(lib.json))],
                ["type": "track", "Metadata": Array(lib.tracks.filter { $0.title.lowercased().contains(text) }.prefix(limit).map { lib.json($0) })],
            ]
            return .json(["MediaContainer": ["size": hubs.count, "Hub": hubs]])
        }
        if path == "/status/sessions/history/all" {
            var plays = lib.history
            if let floor = query["viewedAt>"].flatMap(Int.init) { plays = plays.filter { $0.viewedAt >= floor } }
            if let ceiling = query["viewedAt<"].flatMap(Int.init) { plays = plays.filter { $0.viewedAt <= ceiling } }
            if (query["sort"] ?? "").hasSuffix(":desc") { plays.reverse() }
            let shaped = plays.map { play -> [String: Any] in
                ["ratingKey": play.trackID, "key": "/library/metadata/\(play.trackID)", "type": "track",
                 "title": lib.track(play.trackID)?.title ?? "", "librarySectionID": DemoLibrary.section,
                 "viewedAt": play.viewedAt, "accountID": 1, "deviceID": 7]
            }
            let (chosen, total) = Self.page(shaped, query)
            return .json(Self.container(items: chosen, total: total))
        }
        if path == "/:/rate" {
            if let position = lib.trackPosition(query["key"] ?? "") {
                let rating = Double(query["rating"] ?? "") ?? -1
                library?.tracks[position].userRating = rating < 0 ? nil : rating
                library?.tracks[position].lastRatedAt = rating < 0 ? nil : Int(Date().timeIntervalSince1970)
            }
            return .empty(200)
        }
        if path == "/:/timeline" {
            Logger.demo.debug("[demo] timeline \(query["state"] ?? "?", privacy: .public) \(lib.track(query["ratingKey"] ?? "")?.title ?? "?", privacy: .public) at \((Int(query["time"] ?? "") ?? 0) / 1000)s (stamp \(stamp))")
            return .empty(200)
        }
        return .empty(404)
    }

    private func libraryAll(_ query: [String: String], in lib: DemoLibrary) -> [String: Any] {
        func moodNames(_ keys: String?) -> Set<String>? {
            guard let keys else { return nil }
            let wanted = Set(keys.split(separator: ",").map(String.init))
            return Set(lib.moods.filter { wanted.contains($0.key) }.map(\.name))
        }
        let albumMoods = moodNames(query["album.mood"])
        let ownMoods = moodNames(query["mood"])
        let ratingFloor = query["userRating>"].flatMap(Double.init)

        var items: [DemoItem]
        switch query["type"] ?? "10" {
        case "8": items = lib.artists.map(DemoItem.artist)
        case "9": items = lib.albums.map(DemoItem.album)
        default: items = lib.tracks.map(DemoItem.track)
        }
        if let albumMoods {
            items = items.filter { item in
                guard case .track(let track) = item, let album = lib.album(track.albumID) else { return false }
                return !albumMoods.isDisjoint(with: album.moods)
            }
        }
        if let ownMoods {
            items = items.filter { item in
                guard case .album(let album) = item else { return false }
                return !ownMoods.isDisjoint(with: album.moods)
            }
        }
        if let ratingFloor { items = items.filter { $0.userRating >= ratingFloor } }

        let sort = query["sort"] ?? ""
        if sort == "random" {
            items.shuffle()
        } else if sort.hasPrefix("addedAt") {
            items.sort { sort.hasSuffix("desc") ? $0.addedAt > $1.addedAt : $0.addedAt < $1.addedAt }
        } else if sort.hasPrefix("lastRatedAt") {
            items.sort { sort.hasSuffix("desc") ? $0.lastRatedAt > $1.lastRatedAt : $0.lastRatedAt < $1.lastRatedAt }
        } else if sort.hasPrefix("lastViewedAt") {
            items.sort { sort.hasSuffix("desc") ? $0.lastViewedAt > $1.lastViewedAt : $0.lastViewedAt < $1.lastViewedAt }
        } else if sort == "titleSort" {
            items.sort { $0.titleSort.lowercased() < $1.titleSort.lowercased() }
        } else if sort == "id" {
            items.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        }
        let (chosen, total) = Self.page(items, query)
        return Self.container(items: chosen.map { lib.json($0) }, total: total)
    }

    private func file(_ relative: String?, type: String, request: DemoRequest) -> DemoResponse {
        guard let relative, let assets,
              let data = try? Data(contentsOf: assets.appending(path: relative), options: .alwaysMapped) else { return .empty(404) }
        guard let range = request.headers["range"], let match = range.wholeMatch(of: #/bytes=(\d*)-(\d*)/#) else {
            return DemoResponse(status: 200, headers: [("Content-Type", type), ("Accept-Ranges", "bytes")], body: data)
        }
        var start = 0
        var end = data.count - 1
        if let first = Int(match.1) {
            start = first
            end = Int(match.2) ?? end
        } else if let suffix = Int(match.2) {
            start = max(0, data.count - suffix)
        }
        end = min(end, data.count - 1)
        guard start <= end else { return .empty(416) }
        return DemoResponse(status: 206, headers: [("Content-Type", type), ("Accept-Ranges", "bytes"),
                                                   ("Content-Range", "bytes \(start)-\(end)/\(data.count)")],
                            body: data.subdata(in: start..<(end + 1)))
    }

    // MARK: - Shapes

    private static func container(items: [[String: Any]]? = nil, total: Int? = nil, directories: [[String: Any]]? = nil,
                                  extra: [String: Any] = [:]) -> [String: Any] {
        var body = extra
        if let items {
            body["Metadata"] = items
            body["size"] = items.count
        }
        if let directories {
            body["Directory"] = directories
            body["size"] = directories.count
        }
        if let total { body["totalSize"] = total }
        return ["MediaContainer": body]
    }

    private static func page<T>(_ items: [T], _ query: [String: String]) -> ([T], Int) {
        let start = min(Int(query["X-Plex-Container-Start"] ?? "") ?? 0, items.count)
        guard let size = query["X-Plex-Container-Size"].flatMap(Int.init) else { return (Array(items[start...]), items.count) }
        return (Array(items[start..<min(items.count, start + size)]), items.count)
    }

    /// `server://…/library/metadata/3001,3002` → ["3001", "3002"].
    private static func metadataIDs(in uri: String?) -> [String] {
        guard let tail = uri?.components(separatedBy: "/library/metadata/").last else { return [] }
        return tail.matches(of: #/\d+/#).map { String($0.output) }
    }
}

enum DemoError: Error {
    case missingAssets, badRequest, closed
}

private enum DemoItem {
    case artist(DemoLibrary.Artist)
    case album(DemoLibrary.Album)
    case track(DemoLibrary.Track)

    var id: String {
        switch self {
        case .artist(let artist): artist.id
        case .album(let album): album.id
        case .track(let track): track.id
        }
    }

    var titleSort: String {
        switch self {
        case .artist(let artist): artist.name.hasPrefix("The ") ? String(artist.name.dropFirst(4)) : artist.name
        case .album(let album): album.title
        case .track(let track): track.title
        }
    }

    var addedAt: Int {
        switch self {
        case .artist: 0
        case .album(let album): album.addedAt
        case .track(let track): track.addedAt
        }
    }

    var lastRatedAt: Int {
        if case .track(let track) = self { return track.lastRatedAt ?? 0 }
        return 0
    }

    var lastViewedAt: Int {
        if case .album(let album) = self { return album.lastViewedAt ?? 0 }
        return 0
    }

    var userRating: Double {
        if case .track(let track) = self { return track.userRating ?? 0 }
        return 0
    }
}

struct DemoRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]

    init(head: String) throws {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            throw DemoError.badRequest
        }
        method = String(parts[0])
        path = components.path
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where item.name != "X-Plex-Token" {
            query[item.name] = item.value ?? ""
        }
        self.query = query
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers
    }
}

struct DemoResponse: Sendable {
    let status: Int
    let headers: [(String, String)]
    let body: Data

    static func empty(_ status: Int) -> DemoResponse {
        DemoResponse(status: status, headers: [], body: Data())
    }

    static func json(_ object: [String: Any]) -> DemoResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return DemoResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
    }

    func encoded() -> Data {
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 416: "Range Not Satisfiable", 503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Plex-shaped JSON

extension DemoLibrary {
    func json(_ artist: Artist) -> [String: Any] {
        ["ratingKey": artist.id, "key": "/library/metadata/\(artist.id)/children", "type": "artist", "title": artist.name,
         "titleSort": artist.name.hasPrefix("The ") ? String(artist.name.dropFirst(4)) : artist.name,
         "thumb": "/library/metadata/\(artist.id)/thumb/\(Self.stamp)", "childCount": artist.albumCount]
    }

    func json(_ album: Album) -> [String: Any] {
        var out: [String: Any] = [
            "ratingKey": album.id, "key": "/library/metadata/\(album.id)/children", "type": "album", "title": album.title,
            "parentTitle": album.artistName, "parentRatingKey": album.artistID, "year": album.year,
            "thumb": "/library/metadata/\(album.id)/thumb/\(Self.stamp)", "leafCount": album.trackCount, "addedAt": album.addedAt,
            "Mood": album.moods.map { ["tag": $0] },
        ]
        if let lastViewedAt = album.lastViewedAt { out["lastViewedAt"] = lastViewedAt }
        return out
    }

    func json(_ track: Track, detailed: Bool = false) -> [String: Any] {
        var out: [String: Any] = [
            "ratingKey": track.id, "key": "/library/metadata/\(track.id)", "type": "track", "title": track.title,
            "grandparentTitle": track.artistName, "grandparentRatingKey": track.artistID,
            "parentTitle": track.albumTitle, "parentRatingKey": track.albumID, "parentYear": track.albumYear,
            "index": track.index, "parentIndex": 1, "duration": track.durationMS, "addedAt": track.addedAt,
            "parentThumb": "/library/metadata/\(track.albumID)/thumb/\(Self.stamp)",
            "grandparentThumb": "/library/metadata/\(track.artistID)/thumb/\(Self.stamp)",
        ]
        if let rating = track.userRating { out["userRating"] = rating }
        if let rated = track.lastRatedAt { out["lastRatedAt"] = rated }
        var part: [String: Any] = ["key": "/library/parts/\(track.id)/\(Self.stamp)/file.m4a", "container": "mp4", "duration": track.durationMS]
        if detailed {
            part["Stream"] = [["streamType": 2, "codec": "aac", "selected": true, "loudness": "\(track.loudness)",
                               "gain": "\(track.gain)", "albumGain": "\(track.albumGain)", "peak": "0.98"]]
        }
        out["Media"] = [["container": "mp4", "audioCodec": "aac", "bitrate": 96, "Part": [part]]]
        return out
    }

    func json(_ playlist: Playlist) -> [String: Any] {
        let items = playlistTracks(playlist)
        var out: [String: Any] = [
            "ratingKey": playlist.id, "key": "/playlists/\(playlist.id)/items", "type": "playlist", "title": playlist.title,
            "smart": playlist.smart, "playlistType": "audio", "leafCount": items.count,
            "duration": items.reduce(0) { $0 + $1.durationMS }, "composite": "/playlists/\(playlist.id)/composite/\(Self.stamp)",
        ]
        if let summary = playlist.summary { out["summary"] = summary }
        if playlist.poster != nil { out["thumb"] = "/library/metadata/\(playlist.id)/thumb/\(Self.stamp)" }
        return out
    }

    fileprivate func json(_ item: DemoItem) -> [String: Any] {
        switch item {
        case .artist(let artist): json(artist)
        case .album(let album): json(album)
        case .track(let track): json(track)
        }
    }
}
