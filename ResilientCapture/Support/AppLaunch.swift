import Foundation
import UIKit

/// Composition root + launch-time testing seam.
///
/// This is the one place that decides which concrete `CaptureQueueStore` the app
/// runs against, driven by launch arguments so UI tests (and manual verification)
/// can run against an isolated, deterministic store instead of the real
/// `Documents` queue. Arguments of the form `-key value` are parsed by
/// `UserDefaults`, the standard iOS idiom for test launch flags.
///
/// Supported flags:
///   `-uiTesting YES`            -> use a fresh temp-directory store (never touches real captures)
///   `-seedSampleCaptures <n>`   -> enqueue `n` generated sample images on first appear
enum AppLaunch {
    static var isUITesting: Bool {
        UserDefaults.standard.bool(forKey: "uiTesting")
    }

    static var seedSampleCaptures: Int {
        UserDefaults.standard.integer(forKey: "seedSampleCaptures")
    }

    /// Demo/test flag: start offline, then flip online after N seconds so the
    /// offline banner + auto-resume-on-reconnect can be shown in the Simulator
    /// (where real Wi-Fi can't be scripted). 0 = use the real NWPathMonitor.
    static var simulateReconnectAfter: Int {
        UserDefaults.standard.integer(forKey: "simulateReconnectAfter")
    }

    /// Build the queue model with the appropriate store for this launch.
    @MainActor
    static func makeModel() -> CaptureQueueModel {
        let store: CaptureQueueStore
        if isUITesting {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("UITestQueue-\(UUID().uuidString)", isDirectory: true)
            store = FileCaptureQueueStore(rootURL: dir)
        } else {
            store = FileCaptureQueueStore.makeDefault()
        }
        let transport = BackgroundUploadTransport(endpoint: AppConfig.uploadEndpoint)

        let connectivity: ConnectivityMonitor
        let reconnectAfter = simulateReconnectAfter
        if reconnectAfter > 0 {
            // Start offline, then come online after N seconds to demo resume.
            let scripted = ScriptedConnectivityMonitor(initial: .offline)
            connectivity = scripted
            Task {
                try? await Task.sleep(for: .seconds(Double(reconnectAfter)))
                scripted.set(NetworkStatus(isOnline: true, isExpensive: false, isConstrained: false, interface: .wifi))
            }
        } else {
            connectivity = PathConnectivityMonitor()
        }

        return CaptureQueueModel(store: store, transport: transport, connectivity: connectivity)
    }

    /// If requested via launch flag, seed sample captures so the queue can be
    /// verified end-to-end without driving the system photo picker.
    @MainActor
    static func seedIfRequested(into model: CaptureQueueModel) async {
        let count = seedSampleCaptures
        guard count > 0, model.items.isEmpty else { return }
        for index in 0..<count {
            await model.enqueue(imageData: sampleJPEGData(index: index))
        }
    }

    /// A synthetic capture image, so seeding needs no bundled assets.
    private static func sampleJPEGData(index: Int) -> Data {
        let size = CGSize(width: 800, height: 1000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let palette: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink]
            palette[index % palette.count].setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let label = "SAMPLE #\(index + 1)" as NSString
            label.draw(
                at: CGPoint(x: 40, y: 40),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 64),
                    .foregroundColor: UIColor.white,
                ]
            )
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
