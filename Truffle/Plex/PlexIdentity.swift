import Foundation
import UIKit

/// Who Truffle is to Plex: the headers every plex.tv and server request carries. The client
/// identifier is stable per install, which is what makes Plex list Truffle as one device
/// (and what a sign-in PIN is tied to).
struct PlexIdentity: Sendable, Equatable {
    static let product = "Truffle"

    let clientIdentifier: String
    let version: String
    let platformVersion: String
    let deviceName: String
    let model: String

    var headers: [String: String] {
        [
            "X-Plex-Product": Self.product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Platform": "iOS",
            "X-Plex-Platform-Version": platformVersion,
            "X-Plex-Device": model,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Provides": "player",
            "Accept": "application/json",
        ]
    }

    @MainActor
    static func current(defaults: UserDefaults = .standard) -> PlexIdentity {
        let key = "plex.clientIdentifier"
        let id: String
        if let saved = defaults.string(forKey: key) {
            id = saved
        } else {
            id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: key)
        }
        let device = UIDevice.current
        return PlexIdentity(
            clientIdentifier: id,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            platformVersion: device.systemVersion,
            deviceName: device.name,
            model: device.model
        )
    }
}
