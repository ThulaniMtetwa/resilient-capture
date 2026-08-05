import XCTest
import CryptoKit
@testable import ResilientCapture

/// Tests for the AES-GCM encryption primitive.
final class CaptureCryptoTests: XCTestCase {
    func testRoundTrip() throws {
        let crypto = TestCrypto.make()
        let plaintext = Data("identity document bytes".utf8)

        let sealed = try crypto.seal(plaintext)
        XCTAssertNotEqual(sealed, plaintext, "Sealed data must differ from plaintext")

        let opened = try crypto.open(sealed)
        XCTAssertEqual(opened, plaintext, "Opening a sealed box must recover the plaintext")
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let crypto = TestCrypto.make()
        var sealed = try crypto.seal(Data("secret".utf8))
        sealed[sealed.count - 1] ^= 0xFF   // flip a bit in the auth tag

        XCTAssertThrowsError(try crypto.open(sealed), "GCM must reject tampered ciphertext")
    }

    func testWrongKeyFailsToOpen() throws {
        let sealed = try TestCrypto.make(byte: 0x01).seal(Data("secret".utf8))
        XCTAssertThrowsError(try TestCrypto.make(byte: 0x02).open(sealed), "A different key must not decrypt")
    }

    func testNoncesDifferPerMessage() throws {
        let crypto = TestCrypto.make()
        let a = try crypto.seal(Data("same".utf8))
        let b = try crypto.seal(Data("same".utf8))
        XCTAssertNotEqual(a, b, "Each seal must use a fresh nonce, so identical plaintext yields different ciphertext")
    }
}
