import Foundation
import Observation

/// The view-facing source of truth for the capture queue.
///
/// `@MainActor` so all UI-observed mutation is compiler-checked on the main
/// thread; `@Observable` (iOS 17) so views re-render only for the properties
/// their `body` actually reads. It owns no side effects of its own — the disk
/// `store` is injected — which keeps it testable and lets the app point it at
/// production storage while tests point it at a temp directory.
@MainActor
@Observable
final class CaptureQueueModel {
    /// The queue as shown in the UI, oldest first. Private setter: only this
    /// model mutates it, always in lock-step with the persisted store.
    private(set) var items: [CaptureItem] = []

    /// Surfaced to the UI for a transient error banner.
    var errorMessage: String?

    private let store: CaptureQueueStore

    init(store: CaptureQueueStore) {
        self.store = store
    }

    /// Hydrate the in-memory queue from disk. Call once when the UI appears.
    func load() async {
        do {
            items = try await store.loadAll()
        } catch {
            errorMessage = "Couldn't load the queue: \(error.localizedDescription)"
        }
    }

    /// Persist a freshly captured image as `pending`, then reflect it in the UI.
    ///
    /// The disk write happens *first and is awaited*; only on success does the
    /// item appear in `items`. So the UI never shows a capture that isn't already
    /// durably saved — the persistence-first guarantee, surfaced to the user.
    func enqueue(imageData rawData: Data) async {
        let id = UUID()
        // Bound memory/upload size; fall back to the original bytes if the image
        // can't be decoded, so a capture is never lost to a resize failure.
        let bytes = CaptureImageProcessor.downsampledJPEGData(from: rawData) ?? rawData
        do {
            let item = try await store.writeCapture(id: id, imageData: bytes, createdAt: Date())
            insert(item)
        } catch {
            errorMessage = "Couldn't save the capture: \(error.localizedDescription)"
        }
    }

    /// File URL of an item's image, for rendering. Synchronous and cheap
    /// (the store computes it from immutable state).
    func imageURL(for item: CaptureItem) -> URL {
        store.imageURL(for: item)
    }

    // MARK: - Private

    private func insert(_ item: CaptureItem) {
        items.append(item)
        items.sort { $0.createdAt < $1.createdAt }
    }
}
