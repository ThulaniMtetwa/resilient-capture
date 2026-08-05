import Foundation
import Security

/// Keychain storage for the upload bearer token.
///
/// Stored `afterFirstUnlockThisDeviceOnly` so it is available to background
/// uploads after first unlock, never synced to iCloud, and never in backups.
/// In a real app the token would be issued by a sign-in flow and refreshed; here
/// it is simply read (and can be seeded for the demo).
enum AuthTokenStore {
    private static let service = "com.iidentifii.resilientcapture.auth"
    private static let account = "upload-bearer-token"

    /// The current token, or `nil` if none is stored / the Keychain is unavailable.
    static func currentToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Store (or replace) the token. Not used by the demo path but included so the
    /// production sign-in flow has a home for it.
    @discardableResult
    static func store(_ token: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
