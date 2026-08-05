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
///   `-uiTesting YES`            → use a fresh temp-directory store (never touches real captures)
///   `-seedSampleCaptures <n>`   → enqueue `n` generated sample images on first appear
enum AppLaunch {
    static var isUITesting: Bool {
        UserDefaults.standard.bool(forKey: "uiTesting")
    }

    static var seedSampleCaptures: Int {
        UserDefaults.standard.integer(forKey: "seedSampleCaptures")
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
        return CaptureQueueModel(store: store, transport: transport)
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
