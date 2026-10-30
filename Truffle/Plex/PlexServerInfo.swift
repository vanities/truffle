import Foundation

/// A server on the account, as plex.tv lists it. It's kept in the Keychain because it carries the
/// server's access token.
struct PlexServerInfo: Codable, Sendable, Hashable {
    struct Connection: Codable, Sendable, Hashable {
        let uri: URL
        let local: Bool
        let relay: Bool

        var kind: PlexEndpoint.Kind { relay ? .relay : local ? .local : .remote }
    }

    let name: String
    let machineIdentifier: String
    let accessToken: String
    var connections: [Connection]

    init(name: String, machineIdentifier: String, accessToken: String, connections: [Connection]) {
        self.name = name
        self.machineIdentifier = machineIdentifier
        self.accessToken = accessToken
        self.connections = connections
    }

    /// plex.tv's https `*.plex.direct` addresses, plus plain http to each home-network address:
    /// a router that blocks DNS answers pointing at private IPs (rebind protection) breaks the
    /// plex.direct names at home, but not the bare address.
    init?(resource: PlexResource, fallbackToken: String) {
        guard resource.isServer, !resource.clientIdentifier.isEmpty else { return nil }
        var connections: [Connection] = []
        for connection in resource.connections {
            if let uri = URL(string: connection.uri) {
                connections.append(Connection(uri: uri, local: connection.local, relay: connection.relay))
            }
            if connection.local, !connection.relay, let address = connection.address, !address.contains(":"),
               let port = connection.port, let plain = URL(string: "http://\(address):\(port)") {
                connections.append(Connection(uri: plain, local: true, relay: false))
            }
        }
        var seen = Set<URL>()
        self.init(name: resource.name, machineIdentifier: resource.clientIdentifier,
                  accessToken: resource.accessToken ?? fallbackToken,
                  connections: connections.filter { seen.insert($0.uri).inserted })
    }

    func endpoint(for connection: Connection) -> PlexEndpoint {
        PlexEndpoint(baseURL: connection.uri, kind: connection.kind, machineIdentifier: machineIdentifier, token: accessToken)
    }
}

/// The music library Truffle plays from. Plex calls it a section.
struct MusicSection: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
}
