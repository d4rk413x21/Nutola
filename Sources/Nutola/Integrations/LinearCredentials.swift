import Foundation
import Security

enum LinearCredentials {
    static let changed = Notification.Name("NutolaLinearCredentialsChanged")
    // Use the login Keychain: Nutola also supports ad-hoc signing without access-group entitlements.
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.matheusgois-dd.Nutola.linear",
         kSecAttrAccount as String: "personal-api-key"]
    }

    static func load() throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LinearError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw LinearError.invalidKey }
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LinearError.keychain(status) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LinearError.keychain(status) }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
