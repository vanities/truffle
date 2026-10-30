import Foundation
import Security
import os

/// Small generic-password store. The Plex sign-in and the server (with its token) live here.
struct Keychain: Sendable {
    let service: String

    static let truffle = Keychain(service: "com.vanities.truffle.plex")

    func set(_ data: Data, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // Readable after the first unlock, so CarPlay can play with the phone locked in a pocket.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.store.error("[keychain] write \(account, privacy: .public) failed: \(status)")
        }
    }

    func data(for account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.store.error("[keychain] read \(account, privacy: .public) failed: \(status)")
        }
        return result as? Data
    }

    func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    func setString(_ value: String, for account: String) { set(Data(value.utf8), for: account) }

    func string(for account: String) -> String? { data(for: account).flatMap { String(data: $0, encoding: .utf8) } }

    func setCodable<T: Encodable>(_ value: T, for account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, for: account)
    }

    func codable<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        data(for: account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
