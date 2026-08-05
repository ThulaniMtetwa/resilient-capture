import Foundation
import CryptoKit
@testable import ResilientCapture

/// Deterministic crypto for tests: a fixed key so the store's encryption is
/// exercised without depending on the Keychain.
enum TestCrypto {
    static func make(byte: UInt8 = 0x07) -> CaptureCrypto {
        CaptureCrypto(key: SymmetricKey(data: Data(repeating: byte, count: 32)))
    }
}
