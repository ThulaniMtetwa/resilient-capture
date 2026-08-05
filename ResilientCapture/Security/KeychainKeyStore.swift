import Foundation
import CryptoKit
import Security

/// Loads (or creates on first launch) the app's data-at-rest encryption key from
/// the Keychain.
///
/// Accessibility is `afterFirstUnlockThisDeviceOnly`:
///  - `afterFirstUnlock` so the key is available for background uploads once the
///    user has unlocked the device at least once since boot, while remaining
///    inaccessible (and the captures unreadable) before first unlock.
///  - `ThisDeviceOnly` so the key never syncs to iCloud Keychain and is never
///    included in device backups. A backup of the device therefore contains only
///    ciphertext, with no key to open it.
enum KeychainKeyStore {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    private static let service = "com.iidentifii.resilientcapture.keys"
    private static let account = "capture-encryption-key"

    /// The app's capture-encryption key, created once and reused thereafter.
    static func loadOrCreateCaptureKey() throws -> SymmetricKey {
        if let existing = try loadKeyData() {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try storeKeyData(raw)
        return key
    }

    // MARK: - Private

    private static func loadKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func storeKeyData(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
