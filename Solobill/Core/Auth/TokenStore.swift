import Foundation
import Security

struct StoredToken: Codable, Equatable, Sendable {
    /// The server's id for this token, needed to revoke it on sign out.
    let id: Int
    let token: String
}

protocol TokenStore: Sendable {
    func load() -> StoredToken?
    func save(_ token: StoredToken) throws
    func clear()
}

enum KeychainError: LocalizedError {
    case failed(OSStatus)

    var errorDescription: String? { "The token could not be saved to the Keychain." }
}

/// The only place the token is stored. It stays on this device and is not backed up.
struct KeychainTokenStore: TokenStore {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.octax.mg.api",
            kSecAttrAccount as String: "token",
        ]
    }

    func load() -> StoredToken? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(StoredToken.self, from: data)
    }

    func save(_ token: StoredToken) throws {
        clear()
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(token)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.failed(status) }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
