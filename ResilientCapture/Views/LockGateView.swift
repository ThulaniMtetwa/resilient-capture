import SwiftUI
import Observation

/// Owns the lock state and drives authentication. Extracted from the view so the
/// gating logic can be unit-tested with a fake authenticator.
@MainActor
@Observable
final class LockController {
    private(set) var isUnlocked: Bool
    private let authenticator: BiometricAuthenticator

    init(authenticator: BiometricAuthenticator, gateEnabled: Bool) {
        self.authenticator = authenticator
        self.isUnlocked = !gateEnabled   // no gate => already unlocked
    }

    func authenticate() async {
        guard !isUnlocked else { return }
        isUnlocked = await authenticator.authenticate(reason: "Unlock to view your captures")
    }
}

/// Gates its content behind biometric/passcode authentication.
struct LockGateView<Content: View>: View {
    @State private var controller: LockController
    private let content: () -> Content

    init(
        authenticator: BiometricAuthenticator,
        gateEnabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _controller = State(initialValue: LockController(authenticator: authenticator, gateEnabled: gateEnabled))
        self.content = content
    }

    var body: some View {
        Group {
            if controller.isUnlocked {
                content()
            } else {
                LockedView { Task { await controller.authenticate() } }
            }
        }
        .task { await controller.authenticate() }
    }
}

private struct LockedView: View {
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "faceid")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Captures locked")
                .font(.headline)
            Text("Authenticate to view identity captures.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Unlock", systemImage: "lock.open", action: onUnlock)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
