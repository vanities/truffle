import Foundation
import Network
import Observation
import os

struct ShuffleProgress: Equatable, Sendable {
    let played: Int
    let total: Int
    let round: Int
}

/// The source of truth for the account, the server, and the library on it. Shared by the phone UI
/// and CarPlay. Lists come from a saved snapshot first, so the car has something to show before
/// the server answers.
@MainActor @Observable
final class MusicLibrary {
    enum Phase: Equatable {
        case signedOut
        case connecting
        case ready
        /// Signed in but the server isn't answering; the saved lists still show.
        case unreachable(String)
        case failed(String)
    }

    private(set) var phase: Phase = .signedOut
    private(set) var userName: String?
    private(set) var server: PlexServerInfo?
    private(set) var endpoint: PlexEndpoint?
    private(set) var section: MusicSection?
    private(set) var sections: [MusicSection] = []
    private(set) var artists: [Artist] = []
    private(set) var albums: [Album] = []
    private(set) var playlists: [Playlist] = []
    private(set) var recentlyAdded: [Album] = []
    private(set) var trackCount = 0
    private(set) var likedCount = 0
    private(set) var shuffleProgress: ShuffleProgress?
    private(set) var lastRefresh: Date?
    /// Likes changed in this session, so every list showing a song shows its heart right away
    /// (lists hold the copies they fetched).
    private(set) var likedOverrides: [String: Bool] = [:]

    /// The player swaps upcoming songs onto the new address when the connection changes.
    @ObservationIgnored var onEndpointChanged: ((PlexEndpoint) -> Void)?
    @ObservationIgnored var onSignedOut: (() -> Void)?
    @ObservationIgnored var onTrackUpdated: ((Track) -> Void)?

    let identity: PlexIdentity
    let settings: AppSettings
    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored private let keychain: Keychain
    @ObservationIgnored private(set) var userToken: String?
    @ObservationIgnored var walk: ShuffleWalk?
    /// Big playlists' shuffles, for this session only.
    @ObservationIgnored var playlistWalks: [String: ShuffleWalk] = [:]
    @ObservationIgnored var moodKeys: MoodKeys?
    @ObservationIgnored var earliestPlay: Date?
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private var pathDebounce: Task<Void, Never>?

    private enum KeychainKey {
        static let userToken = "user.token"
        static let server = "server"
        static let userName = "user.name"
    }

    /// Set while the demo is on, so a relaunch (or CarPlay starting the app) resumes it.
    private static let demoDefaultsKey = "demo.active"

    var account: PlexAccountClient { PlexAccountClient(identity: identity) }
    var client: PlexClient? { endpoint.map { PlexClient(endpoint: $0, identity: identity) } }
    var isSignedIn: Bool { userToken != nil }
    var serverName: String { server?.name ?? "your Plex server" }
    /// "Take it for a spin": the invented library DemoServer serves from inside the app.
    var isDemo: Bool { server?.machineIdentifier == DemoLibrary.machineIdentifier }

    init(identity: PlexIdentity, settings: AppSettings, store: LibraryStore = LibraryStore(), keychain: Keychain = .truffle) {
        self.identity = identity
        self.settings = settings
        self.store = store
        self.keychain = keychain
    }

    // MARK: - Start

    func start() {
        let sw = Stopwatch()
        if UserDefaults.standard.bool(forKey: Self.demoDefaultsKey) {
            Logger.library.info("[library] start: resuming the demo")
            startDemo()
            return
        }
        userToken = keychain.string(for: KeychainKey.userToken)
        userName = keychain.string(for: KeychainKey.userName)
        server = keychain.codable(PlexServerInfo.self, for: KeychainKey.server)
        guard userToken != nil else {
            phase = .signedOut
            Logger.library.info("[library] start: signed out")
            return
        }
        restoreSnapshot()
        phase = .connecting
        watchNetwork()
        connect(reason: "launch")
        Logger.library.info("[library] start: signed in as \(self.userName ?? "?", privacy: .public), server=\(self.server?.name ?? "none", privacy: .public), \(self.albums.count) cached albums in \(sw.ms, format: .fixed(precision: 1))ms")
    }

    #if DEBUG
    /// `-TruffleServerURL http://127.0.0.1:32499 -TruffleServerToken demo` points the app at one
    /// server directly (scripts/demo_server.py), skipping plex.tv. For the simulator and screenshots.
    func startWithDirectServer(url: URL, token: String) {
        Logger.library.info("[library] direct server \(url.host() ?? "?", privacy: .public) (debug)")
        userToken = token
        userName = "Demo"
        server = PlexServerInfo(name: "Demo Server", machineIdentifier: "demo", accessToken: token,
                                connections: [.init(uri: url, local: true, relay: false)])
        restoreSnapshot()
        phase = .connecting
        connect(reason: "direct")
    }
    #endif

    // MARK: - Demo

    /// "Take it for a spin": the whole app on an invented library, served from inside the app, for App
    /// Review and anyone without a Plex server. Nothing goes in the Keychain; Sign Out ends it.
    func startDemo() {
        Logger.demo.info("[demo] starting")
        UserDefaults.standard.set(true, forKey: Self.demoDefaultsKey)
        userToken = "demo"
        userName = "Demo"
        server = Self.demoServer(url: nil)
        restoreSnapshot()
        phase = .connecting
        connect(reason: "demo")
    }

    private static func demoServer(url: URL?) -> PlexServerInfo {
        PlexServerInfo(name: "Demo Server", machineIdentifier: DemoLibrary.machineIdentifier, accessToken: "demo",
                       connections: url.map { [.init(uri: $0, local: true, relay: false)] } ?? [])
    }

    // MARK: - Sign in / out

    /// Step one of Plex's PIN sign-in: the page to open in a browser sheet.
    func beginSignIn() async throws -> (pin: PlexPin, url: URL) {
        let pin = try await account.createPin()
        // No forwardUrl: with an app scheme (truffle://) Plex's auth page skips the sign-in form and
        // lands on watch.plex.tv (seen 2026-10-30). Polling notices the sign-in and closes the sheet.
        guard let url = account.authURL(code: pin.code, forwardURL: nil) else { throw PlexError.signInExpired }
        Logger.auth.info("[auth] pin \(pin.id) created, expires in \(pin.expiresIn ?? 0)s")
        #if DEBUG
        // The link code (not a token: it only becomes one when the account owner approves it), so a
        // test run can approve it with PUT plex.tv/api/v2/pins/link instead of typing a password.
        Logger.auth.debug("[auth] pin code \(pin.code, privacy: .public)")
        #endif
        return (pin, url)
    }

    /// Step two: wait for Plex to attach a token to the PIN (the user is signing in meanwhile).
    func waitForSignIn(pin: PlexPin) async throws {
        let sw = Stopwatch()
        let expiry = TimeInterval(pin.expiresIn ?? 900)
        while !Task.isCancelled {
            let checked = try await account.pin(pin.id)
            if let token = checked.authToken, !token.isEmpty {
                Logger.auth.info("[auth] signed in after \(sw.seconds, format: .fixed(precision: 1))s")
                await completeSignIn(token: token)
                return
            }
            if sw.seconds > expiry { throw PlexError.signInExpired }
            try await Task.sleep(for: .seconds(1))
        }
        throw CancellationError()
    }

    /// Checks the PIN once, when the browser hands control back.
    func checkSignIn(pin: PlexPin) async -> Bool {
        guard let checked = try? await account.pin(pin.id), let token = checked.authToken, !token.isEmpty else { return false }
        await completeSignIn(token: token)
        return true
    }

    private func completeSignIn(token: String) async {
        guard userToken != token else { return }
        keychain.setString(token, for: KeychainKey.userToken)
        userToken = token
        if let user = try? await account.user(token: token) {
            userName = user.username ?? user.title
            keychain.setString(userName ?? "", for: KeychainKey.userName)
        }
        phase = .connecting
        watchNetwork()
        connect(reason: "sign in")
    }

    func signOut() {
        Logger.auth.info("[auth] signing out\(self.isDemo ? " of the demo" : "", privacy: .public)")
        if isDemo { Task { await DemoServer.shared.stop() } }
        UserDefaults.standard.removeObject(forKey: Self.demoDefaultsKey)
        connecting?.cancel()
        connecting = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for key in [KeychainKey.userToken, KeychainKey.server, KeychainKey.userName] {
            keychain.delete(key)
        }
        store.removeAll()
        userToken = nil
        userName = nil
        server = nil
        endpoint = nil
        section = nil
        sections = []
        artists = []
        albums = []
        playlists = []
        recentlyAdded = []
        trackCount = 0
        likedCount = 0
        walk = nil
        moodKeys = nil
        earliestPlay = nil
        shuffleProgress = nil
        likedOverrides = [:]
        settings.sectionID = nil
        phase = .signedOut
        onSignedOut?()
    }

    // MARK: - Connecting

    /// `full` also picks the library and reloads its lists; a reconnect only finds an address again.
    func connect(reason: String, full: Bool = true) {
        if connecting != nil {
            Logger.library.debug("[library] connect (\(reason, privacy: .public)) already running")
            return
        }
        connecting = Task { [weak self] in
            await self?.runConnect(reason: reason, full: full)
            self?.connecting = nil
        }
    }

    /// Waits for an in-flight connect, or starts a light one. Used when a request finds the address dead.
    func reconnect(reason: String) async {
        if connecting == nil { connect(reason: reason, full: section == nil) }
        await connecting?.value
    }

    private func runConnect(reason: String, full: Bool) async {
        guard let token = userToken else { return }
        let sw = Stopwatch()
        Logger.library.info("[library] connecting (\(reason, privacy: .public))")
        if phase != .ready { phase = .connecting }
        if isDemo {
            // The demo's port is only known once it's listening, and changes if iOS closed the socket
            // while the app was suspended.
            do {
                server = Self.demoServer(url: try await DemoServer.shared.start())
            } catch {
                Logger.demo.error("[demo] didn't start: \(error.localizedDescription, privacy: .public)")
                phase = .failed("The demo didn't start. Try again?")
                return
            }
        }

        var found: PlexEndpoint?
        if let server { found = await pickEndpoint(for: server) }
        if found == nil, server?.machineIdentifier != "demo", !isDemo {
            // Addresses change (a new public IP); plex.tv has the current ones.
            do {
                found = try await refreshServer(token: token)
            } catch PlexError.unauthorized {
                Logger.auth.error("[auth] plex.tv rejected the saved sign-in")
                signOut()
                return
            } catch let error as PlexError {
                phase = .failed(error.localizedDescription)
                return
            } catch {
                Logger.library.error("[library] plex.tv unreachable: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let found else {
            phase = .unreachable("\(serverName) isn't answering.")
            Logger.library.error("[library] no address for \(self.serverName, privacy: .public) answered (\(sw.ms, format: .fixed(precision: 0))ms)")
            return
        }
        use(found)
        if !full, section != nil {
            phase = .ready
            Logger.library.info("[library] reconnected via \(found.kind.rawValue, privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
            return
        }
        let client = PlexClient(endpoint: found, identity: identity)
        do {
            try await chooseSection(client: client)
            try await refreshLists(client: client)
            phase = .ready
            Logger.library.info("[library] ready via \(found.kind.rawValue, privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        } catch PlexError.unauthorized {
            signOut()
        } catch let error as PlexError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .unreachable("\(serverName) isn't answering.")
            Logger.library.error("[library] connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshServer(token: String) async throws -> PlexEndpoint? {
        let resources = try await account.servers(token: token)
        let ordered = resources.sorted { ($0.owned ?? false) && !($1.owned ?? false) }
        let servers = ordered.compactMap { PlexServerInfo(resource: $0, fallbackToken: token) }
        guard let chosen = servers.first(where: { $0.machineIdentifier == server?.machineIdentifier }) ?? servers.first else {
            throw PlexError.noServer
        }
        server = chosen
        keychain.setCodable(chosen, for: KeychainKey.server)
        Logger.library.info("[library] server \(chosen.name, privacy: .public) with \(chosen.connections.count) address(es)")
        return await pickEndpoint(for: chosen)
    }

    private func pickEndpoint(for server: PlexServerInfo) async -> PlexEndpoint? {
        let sw = Stopwatch()
        let probe = ConnectionPicker.identityProbe(machineIdentifier: server.machineIdentifier, identity: identity)
        let picked = await ConnectionPicker.pick(server.connections, probe: probe)
        Logger.library.info("[library] picked \(picked?.kind.rawValue ?? "nothing", privacy: .public) of \(server.connections.count) in \(sw.ms, format: .fixed(precision: 0))ms")
        return picked.map(server.endpoint(for:))
    }

    private func use(_ newEndpoint: PlexEndpoint) {
        let changed = endpoint != newEndpoint
        endpoint = newEndpoint
        if changed { onEndpointChanged?(newEndpoint) }
    }

    /// Runs a request, and once more on a fresh connection if the address went dead (the phone left
    /// home Wi-Fi mid-drive).
    @discardableResult
    func withClient<T>(_ label: String, _ body: (PlexClient) async throws -> T) async throws -> T {
        if client == nil { await reconnect(reason: label) }
        guard let client else { throw PlexError.unreachable(server: serverName) }
        do {
            return try await body(client)
        } catch let error as URLError where Self.isConnectivity(error) {
            guard connecting == nil else { throw error }
            Logger.library.info("[library] \(label, privacy: .public) lost the connection (\(error.code.rawValue)); reconnecting")
            endpoint = nil
            await reconnect(reason: label)
            guard let fresh = self.client else { throw error }
            return try await body(fresh)
        }
    }

    static func isConnectivity(_ error: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
         .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
            Task { @MainActor [weak self] in self?.pathChanged(signature: signature, satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "truffle.path"))
        pathMonitor = monitor
    }

    private func pathChanged(signature: String, satisfied: Bool) {
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature, satisfied, isSignedIn else { return }
        Logger.library.info("[library] network changed (\(last, privacy: .public) → \(signature, privacy: .public))")
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.endpoint = nil
            self.connect(reason: "network changed", full: false)
        }
    }

    // MARK: - Library

    private func chooseSection(client: PlexClient) async throws {
        let container = try await client.get("/library/sections")
        let music = container.directories.filter { $0.type == "artist" }.map { MusicSection(id: $0.key, title: $0.title) }
        sections = music
        guard !music.isEmpty else { throw PlexError.noMusicLibrary }
        if let saved = settings.sectionID, let match = music.first(where: { $0.id == saved }) {
            setSection(match)
            return
        }
        // Most people have one music library; with several, the one with the most songs is the music
        // (a second "artist" library is often audiobooks).
        var best = music[0]
        var bestCount = -1
        for candidate in music {
            let count = (try? await client.get("/library/sections/\(candidate.id)/all",
                                                PlexQuery([("type", "10")]).page(start: 0, size: 0)).totalSize) ?? 0
            Logger.library.info("[library] section \(candidate.title, privacy: .public) has \(count) songs")
            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }
        setSection(best)
    }

    func setSection(_ newSection: MusicSection) {
        guard section != newSection else { return }
        let switching = section != nil && section?.id != newSection.id
        section = newSection
        settings.sectionID = newSection.id
        guard switching || walk == nil else { return }
        moodKeys = nil
        earliestPlay = nil
        loadWalk()
        if switching {
            artists = []
            albums = []
            playlists = []
            recentlyAdded = []
            Task { await refresh() }
        }
        Logger.library.info("[library] using section \(newSection.title, privacy: .public) (\(newSection.id, privacy: .public))")
    }

    /// Pull to refresh, or after switching libraries.
    func refresh() async {
        guard let client else {
            connect(reason: "refresh")
            return
        }
        do {
            try await refreshLists(client: client)
        } catch let error as URLError where Self.isConnectivity(error) {
            guard connecting == nil else { return }
            endpoint = nil
            connect(reason: "refresh lost the connection")
        } catch {
            Logger.library.error("[library] refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshLists(client: PlexClient) async throws {
        guard let section else { return }
        let sw = Stopwatch()
        let base = "/library/sections/\(section.id)/all"
        async let artistsResult = client.get(base, PlexQuery([("type", "8"), ("sort", "titleSort")]))
        async let albumsResult = client.get(base, PlexQuery([("type", "9"), ("sort", "titleSort")]))
        async let recentResult = client.get(base, PlexQuery([("type", "9"), ("sort", "addedAt:desc")]).page(start: 0, size: 30))
        async let playlistsResult = client.get("/playlists", PlexQuery([("playlistType", "audio")]))
        async let countResult = client.get(base, PlexQuery([("type", "10")]).page(start: 0, size: 0))
        // `userRating>` + `=8` is Plex's `userRating>=8`: four stars and up, which includes loves.
        async let likedResult = client.get(base, PlexQuery([("type", "10"), ("userRating>", "8")]).page(start: 0, size: 0))
        let (artistList, albumList, recentList, playlistList, count, liked) = try await (artistsResult, albumsResult, recentResult,
                                                                                        playlistsResult, countResult, likedResult)
        artists = artistList.metadata.compactMap(Artist.init)
        albums = albumList.metadata.compactMap(Album.init)
        recentlyAdded = recentList.metadata.compactMap(Album.init)
        playlists = playlistList.metadata.compactMap(Playlist.init)
        trackCount = count.totalSize ?? count.size ?? trackCount
        likedCount = liked.totalSize ?? liked.size ?? likedCount
        lastRefresh = .now
        resizeWalk(to: trackCount)
        saveSnapshot()
        Logger.library.info("[library] refreshed \(self.artists.count) artists, \(self.albums.count) albums, \(self.playlists.count) playlists, \(self.trackCount) songs, \(self.likedCount) liked in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    // MARK: - Snapshot

    private var snapshotName: String { "library.json" }

    private func restoreSnapshot() {
        guard let snapshot = store.load(LibrarySnapshot.self, from: snapshotName),
              snapshot.machineIdentifier == server?.machineIdentifier,
              settings.sectionID == nil || snapshot.sectionID == settings.sectionID else { return }
        artists = snapshot.artists
        albums = snapshot.albums
        playlists = snapshot.playlists
        recentlyAdded = snapshot.recentlyAdded
        trackCount = snapshot.trackCount
        likedCount = snapshot.likedCount
        lastRefresh = snapshot.savedAt
        if section == nil {
            section = MusicSection(id: settings.sectionID ?? snapshot.sectionID, title: "Music")
            loadWalk()
        }
        Logger.library.info("[library] restored snapshot from \(snapshot.savedAt.formatted(.relative(presentation: .named)), privacy: .public)")
    }

    private func saveSnapshot() {
        guard let server, let section else { return }
        store.save(LibrarySnapshot(machineIdentifier: server.machineIdentifier, sectionID: section.id, artists: artists,
                                   albums: albums, playlists: playlists, recentlyAdded: recentlyAdded,
                                   trackCount: trackCount, likedCount: likedCount, savedAt: .now), to: snapshotName)
    }

    // MARK: - Shuffle walk

    private var walkName: String { "shuffle-\(section?.id ?? "none").json" }

    private func loadWalk() {
        walk = store.load(ShuffleWalk.self, from: walkName)
        publishWalk()
    }

    func saveWalk() {
        guard let walk else { return }
        store.save(walk, to: walkName)
        publishWalk()
    }

    private func resizeWalk(to total: Int) {
        guard total > 0 else { return }
        if walk == nil {
            walk = ShuffleWalk(total: total)
            Logger.shuffle.info("[shuffle] new walk over \(total) songs")
        } else if walk?.total != total {
            Logger.shuffle.info("[shuffle] library went \(self.walk?.total ?? 0) → \(total) songs")
            walk?.resize(to: total)
        }
        saveWalk()
    }

    /// Throws away this round's progress and starts a new random order.
    func startNewShuffleRound() {
        guard trackCount > 0 else { return }
        walk = ShuffleWalk(total: trackCount, round: (walk?.round ?? 0) + 1)
        Logger.shuffle.info("[shuffle] new round \(self.walk?.round ?? 0) by request")
        saveWalk()
    }

    private func publishWalk() {
        shuffleProgress = walk.map { ShuffleProgress(played: $0.played, total: $0.total, round: $0.round) }
    }

    func playlistsChanged(_ list: [Playlist]) {
        playlists = list
        saveSnapshot()
    }

    // MARK: - Ratings bookkeeping

    func isLiked(_ track: Track) -> Bool { likedOverrides[track.id] ?? track.isLiked }

    func noteRatingChanged(_ track: Track, wasLiked: Bool) {
        if track.isLiked != wasLiked { likedCount = max(0, likedCount + (track.isLiked ? 1 : -1)) }
        likedOverrides[track.id] = track.isLiked
        onTrackUpdated?(track)
    }
}
