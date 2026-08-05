import Foundation
import Observation

/// The view-facing source of truth for the capture queue.
///
/// `@MainActor` so all UI-observed mutation is compiler-checked on the main
/// thread; `@Observable` (iOS 17) so views re-render only for the properties
/// their `body` actually reads. It owns no side effects of its own — the disk
/// `store`, the `UploadManager`, and the `ConnectivityMonitor` are injected /
/// composed here — which keeps it testable and lets the app point it at
/// production storage + a real background transport while tests point it at a
/// temp directory + fakes.
@MainActor
@Observable
final class CaptureQueueModel {
    /// The queue as shown in the UI, oldest first. Private setter: only this
    /// model mutates it, always in lock-step with the persisted store.
    private(set) var items: [CaptureItem] = []

    /// Latest network status, surfaced to the status banner.
    private(set) var networkStatus: NetworkStatus = .unknownOnline

    /// Surfaced to the UI for a transient error banner.
    var errorMessage: String?

    private let store: CaptureQueueStore
    private let uploadManager: UploadManager
    private let connectivity: ConnectivityMonitor
    private var connectivityTask: Task<Void, Never>?

    init(
        store: CaptureQueueStore,
        transport: UploadTransport,
        connectivity: ConnectivityMonitor,
        policy: RetryPolicy = RetryPolicy()
    ) {
        self.store = store
        self.connectivity = connectivity
        self.uploadManager = UploadManager(store: store, transport: transport, policy: policy)
        self.uploadManager.onItemChanged = { [weak self] item in
            self?.apply(item)
        }
    }

    // MARK: - Lifecycle

    /// Bring the pipeline to life: start consuming outcomes, seed the manager
    /// with the current connectivity, hydrate from disk, then reconcile + resume.
    func start() async {
        uploadManager.start()

        // Seed connectivity synchronously so `resume()` knows whether it's online.
        let initial = connectivity.currentStatus()
        networkStatus = initial
        await uploadManager.connectivityChanged(to: initial)
        observeConnectivity()

        await load()
        await uploadManager.resume()
    }

    /// Re-drive interrupted uploads. Called when returning to the foreground.
    func resumeUploads() async {
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

    // MARK: - Actions

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

    // MARK: - Derived UI state

    var pendingCount: Int { items.lazy.filter { $0.state == .pending }.count }
    var uploadingCount: Int { items.lazy.filter { $0.state == .uploading }.count }
    var uploadedCount: Int { items.lazy.filter { $0.state == .uploaded }.count }
    var failedCount: Int { items.lazy.filter { $0.state == .failed }.count }

    /// The single most relevant status line for the banner, or `nil` (no banner).
    /// Priority: offline → uploading → failed → waiting → all-done.
    var statusMessage: StatusMessage? {
        let total = items.count
        guard total > 0 else { return nil }

        if !networkStatus.isOnline {
            return StatusMessage(
                text: "Offline · captures are saved and will upload when you reconnect.",
                systemImage: "wifi.slash",
                tone: .offline
            )
        }
        if uploadingCount > 0 {
            let over = networkStatus.isExpensive ? " over \(networkStatus.interface.rawValue)" : ""
            let noun = uploadingCount == 1 ? "capture" : "captures"
            return StatusMessage(
                text: "Uploading \(uploadingCount) \(noun)\(over)…",
                systemImage: "arrow.up.circle",
                tone: .info,
                showsActivity: true
            )
        }
        if failedCount > 0 {
            let noun = failedCount == 1 ? "upload" : "uploads"
            return StatusMessage(
                text: "\(failedCount) \(noun) failed · tap Retry to try again.",
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning
            )
        }
        if pendingCount > 0 {
            return StatusMessage(
                text: "Waiting to upload \(pendingCount)…",
                systemImage: "clock",
                tone: .info
            )
        }
        if uploadedCount == total {
            let lowData = networkStatus.isConstrained ? " (Low Data Mode)" : ""
            return StatusMessage(
                text: "All \(total) captures uploaded\(lowData).",
                systemImage: "checkmark.circle.fill",
                tone: .success
            )
        }
        return nil
    }

    // MARK: - Private

    private func observeConnectivity() {
        guard connectivityTask == nil else { return }
        connectivityTask = Task { [weak self] in
            guard let stream = self?.connectivity.statusUpdates() else { return }
            for await status in stream {
                guard let self else { break }
                self.networkStatus = status
                await self.uploadManager.connectivityChanged(to: status)
            }
        }
    }

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
