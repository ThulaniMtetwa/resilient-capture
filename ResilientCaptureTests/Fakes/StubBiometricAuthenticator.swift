import Foundation
@testable import ResilientCapture

/// A biometric authenticator with a fixed, scripted result for tests.
struct StubBiometricAuthenticator: BiometricAuthenticator {
    let result: Bool
    func authenticate(reason: String) async -> Bool { result }
}
