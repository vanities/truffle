import Foundation
import os

/// Picks how to reach a server: directly on the home network first, then its public address, and
/// Plex's relay only as a last resort (it's bandwidth-capped).
///
/// Every address is tried at once. A home-network answer wins outright; any other answer waits a
/// short grace period for a better one, so leaving the house costs one quick probe round instead of
/// a timeout per dead address.
enum ConnectionPicker {
    typealias Connection = PlexServerInfo.Connection
    typealias Probe = @Sendable (URL) async -> Bool

    private enum Outcome: Sendable {
        case answered(Connection)
        case failed
        case graceOver
    }

    static func rank(_ kind: PlexEndpoint.Kind) -> Int {
        switch kind {
        case .local: 0
        case .remote: 1
        case .relay: 2
        }
    }

    static func pick(_ connections: [Connection], grace: Duration = .milliseconds(700),
                     probe: @escaping Probe) async -> Connection? {
        await withTaskGroup(of: Outcome.self) { group in
            for connection in connections {
                group.addTask { await probe(connection.uri) ? .answered(connection) : .failed }
            }
            var best: Connection?
            var waiting = false
            for await outcome in group {
                switch outcome {
                case .answered(let connection):
                    if best.map({ rank(connection.kind) < rank($0.kind) }) ?? true { best = connection }
                    if connection.kind == .local {
                        group.cancelAll()
                        return connection
                    }
                    if !waiting {
                        waiting = true
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .graceOver
                        }
                    }
                case .failed:
                    continue
                case .graceOver:
                    group.cancelAll()
                    return best
                }
            }
            return best
        }
    }

    /// GET /identity with a short timeout: true only when the answer is the server we expect
    /// (a home-network address can belong to something else on another network).
    static func identityProbe(machineIdentifier: String, identity: PlexIdentity, timeout: TimeInterval = 4) -> Probe {
        { base in
            let sw = Stopwatch()
            var request = URLRequest(url: base.appending(path: "identity"), timeoutInterval: timeout)
            for (name, value) in identity.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
                let container = try JSONDecoder().decode(PlexEnvelope<PlexContainer>.self, from: data).container
                let matches = container.machineIdentifier == machineIdentifier
                Logger.plex.info("[connect] \(base.host() ?? "?", privacy: .public) answered in \(sw.ms, format: .fixed(precision: 0))ms matches=\(matches)")
                return matches
            } catch {
                Logger.plex.debug("[connect] \(base.host() ?? "?", privacy: .public) no answer after \(sw.ms, format: .fixed(precision: 0))ms: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }
}
