import Foundation
import CryptoKit

/// Authenticated encryption for capture bytes at rest, using AES-256-GCM.
///
/// GCM gives confidentiality and integrity in one pass: the sealed box carries a
/// per-message nonce and an authentication tag, so tampered ciphertext fails to
/// open rather than decrypting to garbage. This is pure, deterministic-given-key
/// logic, so it is a plain value type (no protocol): tests inject a fixed key,
/// production injects a Keychain-backed key.
struct CaptureCrypto: Sendable {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Encrypt plaintext into a self-contained blob (nonce + ciphertext + tag).
    func seal(_ plaintext: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.sealFailed
        }
        return combined
    }

    /// Decrypt a blob produced by `seal`. Throws if the data was tampered with
    /// or the key is wrong (GCM tag mismatch).
    func open(_ ciphertext: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    enum CryptoError: Error {
        case sealFailed
    }
}
