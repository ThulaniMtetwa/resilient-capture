import Foundation
import CryptoKit
import os

/// Supplies the data-at-rest encryption key, preferring the Keychain and falling
/// back to a protected key file only where the Keychain is unavailable.
///
/// The Keychain is the correct home for this key and is used by any normal
/// (code-signed) build on device or Simulator. Unsigned builds have no
/// application-identifier entitlement, so `SecItem` calls are refused
/// (`errSecMissingEntitlement`); to keep the proof of concept runnable there, the
/// key falls back to a file under the app container, written with Data Protection
/// (`completeUntilFirstUserAuthentication`) and excluded from backup. The
/// fallback is weaker than the Keychain and is a dev/Simulator convenience, not
/// the production posture.
enum CaptureKeyProvider {
    private static let log = Logger(subsystem: "com.iidentifii.resilientcapture", category: "keys")

    static func loadOrCreateKey(rootURL: URL) -> SymmetricKey {
        if let key = try? KeychainKeyStore.loadOrCreateCaptureKey() {
            return key
        }
        log.warning("Keychain unavailable; using protected key-file fallback (expected only in unsigned builds)")
        return FileKeyStore.loadOrCreateKey(rootURL: rootURL)
    }
}

/// Fallback key storage: 32 random bytes in a Data-Protected, backup-excluded
/// file. Only used when the Keychain is unavailable.
private enum FileKeyStore {
    static func loadOrCreateKey(rootURL: URL) -> SymmetricKey {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let keyURL = rootURL.appendingPathComponent(".capture-key", isDirectory: false)

        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try? raw.write(to: keyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = keyURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return key
    }
}
