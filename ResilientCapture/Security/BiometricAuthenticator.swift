import Foundation
import LocalAuthentication

/// The **local-auth seam**: unlocking access to the captures with Face ID / Touch
/// ID (or device passcode). A protocol so the gate logic is testable with a fake,
/// since biometrics can't be scripted in a unit test.
protocol BiometricAuthenticator: Sendable {
    /// Prompt for authentication. Returns whether access is granted.
    func authenticate(reason: String) async -> Bool
}

/// A fixed-result authenticator, used only by the `-forceLocked` demo flag so the
/// locked state can be shown in the Simulator (which has no enrolled biometrics).
struct FixedResultAuthenticator: BiometricAuthenticator {
    let result: Bool
    func authenticate(reason: String) async -> Bool { result }
}

/// Production authenticator using `LocalAuthentication`.
struct LABiometricAuthenticator: BiometricAuthenticator {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // `.deviceOwnerAuthentication` allows a passcode fallback when biometrics
        // fail or aren't enrolled.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics or passcode configured: there is nothing to gate
            // against, so don't lock the user out of their own device.
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
