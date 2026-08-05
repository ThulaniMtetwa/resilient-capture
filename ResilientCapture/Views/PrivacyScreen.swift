import SwiftUI

/// Full-screen cover shown whenever the app is not active, so identity thumbnails
/// never appear in the app-switcher snapshot iOS takes on backgrounding.
struct PrivacyScreen: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                Text("ResilientCapture")
                    .font(.headline)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Pure decision for when to obscure the UI, so it can be unit-tested without a
/// running scene.
enum PrivacyScreenPolicy {
    static func shouldObscure(for phase: ScenePhase) -> Bool {
        phase != .active
    }
}
