import Foundation
import Security

/// Stores the fal.ai API key in the login keychain. The key is never shown in
/// the UI once saved; the FAL_KEY environment variable works as a fallback.
enum FalKeyStore {
    private static let service = "dev.francescooddo.macbuddy.fal"
    private static let account = "FAL_KEY"

    static var keyIsAvailable: Bool {
        resolveKey() != nil
    }

    static var hasStoredKey: Bool {
        storedKey() != nil
    }

    /// Keychain first, then environment.
    static func resolveKey() -> String? {
        if let stored = storedKey(), !stored.isEmpty {
            return stored
        }
        if let env = ProcessInfo.processInfo.environment["FAL_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func storedKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
