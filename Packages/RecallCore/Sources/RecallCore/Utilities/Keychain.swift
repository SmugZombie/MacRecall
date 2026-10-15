import Foundation
import Security

/// API keys and AWS secrets live in the login keychain, never in UserDefaults or the database.
public enum Keychain {
    public enum Account: String, CaseIterable, Sendable {
        case openAIAPIKey = "openai.apiKey"
        case lmStudioAPIKey = "lmstudio.apiKey"
        case bedrockAPIKey = "bedrock.apiKey"
        case awsAccessKeyID = "bedrock.accessKeyID"
        case awsSecretAccessKey = "bedrock.secretAccessKey"
        case awsSessionToken = "bedrock.sessionToken"
        /// Read-only token for checking releases of a private GitHub repository.
        case githubToken = "github.token"
    }

    static let service = "RecallForMac"

    public static func get(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or deletes the item when it's empty.
    @discardableResult
    public static func set(_ value: String, for account: Account) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func has(_ account: Account) -> Bool { !(get(account) ?? "").isEmpty }

    // MARK: Keys that must survive errors

    public struct Failure: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The keychain couldn't be read: \(message)"
        }
    }

    /// Returns nil only when the item doesn't exist. Any other failure (a locked keychain, a denied
    /// prompt) throws, so callers never mistake an unreadable key for a missing one and replace it.
    static func data(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        return data
    }

    /// Updates in place (never delete-then-add, which could lose the item between the two calls).
    static func setData(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }
}
