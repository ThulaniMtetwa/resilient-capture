import SwiftUI

@main
struct ResilientCaptureApp: App {
    /// The app owns the queue model for its whole lifetime. `@State` on an
    /// `@Observable` object is the iOS 17 ownership pattern: created once,
    /// survives view updates. The concrete disk store is injected here - the
    /// one place that knows about production storage.
    @State private var model = AppLaunch.makeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
