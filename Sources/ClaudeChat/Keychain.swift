import Foundation
import Security

/// Stores API keys in the macOS login Keychain rather than in a plain file.
/// Each key lives under its own account name; "default" is the original single key.
enum Keychain {
    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ClaudeChat.anthropic-api-key",
            kSecAttrAccount as String: account,
        ]
    }

    static func load(account: String = "default") -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String, account: String = "default") -> Bool {
        delete(account: account)
        var q = base(account)
        q[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String = "default") {
        SecItemDelete(base(account) as CFDictionary)
    }
}
