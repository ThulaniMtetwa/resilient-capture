import Foundation
import Observation

/// The view-facing source of truth for the capture queue.
///
/// `@MainActor` so all UI-observed mutation is compiler-checked on the main
/// thread; `@Observable` (iOS 17) so views re-render only for the properties
/// their `body` actually reads. It owns no side effects of its own — the disk
/// `store` and the `UploadManager` are injected/composed here — which keeps it
/// testable and lets the app point it at production storage + a real background
/// transport while tests point it at a temp directory + a fake transport.
@MainActor
@Observable
final class CaptureQueueModel {
    /// The queue as shown in the UI, oldest first. Private setter: only this
    /// model mutates it, always in lock-step with the persisted store.
    private(set) var items: [CaptureItem] = []

    /// Surfaced to the UI for a transient error banner.
    var errorMessage: String?

    private let store: CaptureQueueStore
    private let uploadManager: UploadManager

    init(store: CaptureQueueStore, transport: UploadTransport, policy: RetryPolicy = RetryPolicy()) {
        self.store = store
        self.uploadManager = UploadManager(store: store, transport: transport, policy: policy)
        // The manager pushes every persisted state change back here so the UI
        // reflects disk. `weak self` avoids a retain cycle (model owns manager).
        self.uploadManager.onItemChanged = { [weak self] item in
            self?.apply(item)
        }
    }

    /// Bring the pipeline to life: start consuming outcomes, hydrate from disk,
    /// then reconcile + resume any interrupted uploads. Call once when the UI appears.
    func start() async {
        uploadManager.start()
        await load()
        await uploadManager.resume()
    }

    /// Hydrate the in-memory queue from disk.
    func load() async {
        do {
            items = try await store.loadAll()
        } catch {
            errorMessage = "Couldn't load the queue: \(error.localizedDescription)"
        }
    }

    /// Persist a freshly captured image as `pending`, reflect it, then hand it to
    /// the upload manager. The disk write is awaited first, so the UI never shows
    /// a capture that isn't already durably saved.
    func enqueue(imageData rawData: Data) async {
        let id = UUID()
        let bytes = CaptureImageProcessor.downsampledJPEGData(from: rawData) ?? rawData
        do {
            let item = try await store.writeCapture(id: id, imageData: bytes, createdAt: Date())
            apply(item)
            await uploadManager.enqueueNew(item)
        } catch {
            errorMessage = "Couldn't save the capture: \(error.localizedDescription)"
        }
    }

    /// Manual retry for a failed item.
    func retry(id: UUID) async {
        await uploadManager.retry(id: id)
    }

    /// File URL of an item's image, for rendering.
    func imageURL(for item: CaptureItem) -> URL {
        store.imageURL(for: item)
    }

    // MARK: - Private

    /// Upsert an item into the in-memory list, keeping it oldest-first.
    private func apply(_ item: CaptureItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            items.sort { $0.createdAt < $1.createdAt }
        }
    }
}
