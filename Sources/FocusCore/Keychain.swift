import Foundation
import Security

public enum Keychain {
    public static let githubAccount = "github-token"
    private static let service = "com.focustracker.app"

    public enum KeychainError: LocalizedError {
        case failed(OSStatus)
        public var errorDescription: String? {
            if case .failed(let status) = self { return "Keychain error (\(status))" }
            return nil
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public static func set(_ value: String, account: String) throws {
        delete(account: account)
        var attributes = query(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.failed(status) }
    }

    public static func get(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
