import XCTest
import SwiftUI
@testable import ResilientCapture

/// Tests for the biometric lock gate and the privacy-screen policy.
@MainActor
final class AppLockTests: XCTestCase {

    func testGateDisabledStartsUnlocked() {
        let controller = LockController(authenticator: StubBiometricAuthenticator(result: false), gateEnabled: false)
        XCTAssertTrue(controller.isUnlocked, "With the gate off, content is available immediately")
    }

    func testSuccessfulAuthUnlocks() async {
        let controller = LockController(authenticator: StubBiometricAuthenticator(result: true), gateEnabled: true)
        XCTAssertFalse(controller.isUnlocked)
        await controller.authenticate()
        XCTAssertTrue(controller.isUnlocked)
    }

    func testFailedAuthStaysLocked() async {
        let controller = LockController(authenticator: StubBiometricAuthenticator(result: false), gateEnabled: true)
        await controller.authenticate()
        XCTAssertFalse(controller.isUnlocked, "A failed authentication must keep the captures locked")
    }

    func testPrivacyScreenShownWhenNotActive() {
        XCTAssertTrue(PrivacyScreenPolicy.shouldObscure(for: .inactive))
        XCTAssertTrue(PrivacyScreenPolicy.shouldObscure(for: .background))
        XCTAssertFalse(PrivacyScreenPolicy.shouldObscure(for: .active))
    }
}
