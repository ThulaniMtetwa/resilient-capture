import SwiftUI

@main
struct ResilientCaptureApp: App {
    /// The app owns the queue model for its whole lifetime. `@State` on an
    /// `@Observable` object is the iOS 17 ownership pattern: created once,
    /// survives view updates. The concrete disk store is injected here - the
    /// one place that knows about production storage.
    @State private var model = AppLaunch.makeModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LockGateView(
                authenticator: AppLaunch.makeAuthenticator(),
                gateEnabled: AppLaunch.biometricGateEnabled
            ) {
                ContentView(model: model)
            }
            // Privacy screen: cover identity content whenever the app is not
            // active, so it never leaks into the app-switcher snapshot.
            .overlay {
                if PrivacyScreenPolicy.shouldObscure(for: scenePhase) {
                    PrivacyScreen()
                }
            }
        }
    }
}
