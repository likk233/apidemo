import Foundation
import Security

public struct KeychainStore {
    private let service = "com.usagebar.mac.deepseek"
    public init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
    }
    public func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw UsageError.keychain(status) }
        return key
    }
    public func save(_ key: String) throws {
        guard let data = key.data(using: .utf8), !key.isEmpty else { throw UsageError.invalidResponse }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(q as CFDictionary, nil)
            guard add == errSecSuccess else { throw UsageError.keychain(add) }
        } else if status != errSecSuccess { throw UsageError.keychain(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UsageError.keychain(status) }
    }
}
