import Foundation
import os

/// Orchestrates the upload lifecycle: which items to send, how state transitions,
/// and how failures are retried. This is the testable heart of the pipeline —
/// it depends only on the `CaptureQueueStore` and `UploadTransport` protocols and
/// a pure `RetryPolicy`, so tests drive it with a fake transport and assert real
/// state transitions with no networking.
///
/// State-machine rules:
///   • `pending`   → enqueue → `uploading`
///   • success     → `uploaded` (terminal)
///   • retryable failure, attempts remain → stays `uploading`, backoff, re-enqueue
///   • retryable failure, attempts exhausted, or non-retryable → `failed`
///     (`failed` means "needs a human"; auto-retry never lands here)
///
/// `@MainActor` so it can push updated items straight to the UI via `onItemChanged`
/// without thread hops; the durable store remains the source of truth.
@MainActor
final class UploadManager {
    /// Called whenever an item's persisted state changes, so the UI can update.
    var onItemChanged: ((CaptureItem) -> Void)?

    private let store: CaptureQueueStore
    private let transport: UploadTransport
    private let policy: RetryPolicy
    private let log = Logger(subsystem: "com.iidentifii.resilientcapture", category: "manager")

    private var consumeTask: Task<Void, Never>?
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    init(store: CaptureQueueStore, transport: UploadTransport, policy: RetryPolicy = RetryPolicy()) {
        self.store = store
        self.transport = transport
        self.policy = policy
    }

    /// Begin consuming upload outcomes. Idempotent; call once.
    func start() {
        guard consumeTask == nil else { return }
        let stream = transport.makeOutcomeStream()
        consumeTask = Task { [weak self] in
            for await completion in stream {
                await self?.handle(completion)
            }
        }
    }

    /// Reconcile persisted state against the transport and (re)enqueue work.
    ///
    /// Called on launch and when returning to foreground / regaining
    /// connectivity. An item recorded as `uploading` that the transport isn't
    /// actually carrying (app was killed mid-flight) is re-driven; the capture
    /// UUID + server idempotency make a possible double-delivery harmless.
    func resume() async {
        let items = (try? await store.loadAll()) ?? []
        let inFlight = await transport.inFlightIDs()
        for item in items {
            switch item.state {
            case .pending:
                await enqueue(item)
            case .uploading where !inFlight.contains(item.id):
                await enqueue(item)
            case .uploading, .uploaded, .failed:
                continue   // in flight, done, or waiting for manual retry
            }
        }
    }

    /// Enqueue a brand-new capture straight after it's persisted as `pending`.
    func enqueueNew(_ item: CaptureItem) async {
        await enqueue(item)
    }

    /// Manual retry for a `failed` item: reset its attempt budget and try again.
    func retry(id: UUID) async {
        guard var item = await store.load(id: id) else { return }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        item.attemptCount = 0
        item.lastError = nil
        await enqueue(item)
    }

    // MARK: - Core transitions

    private func enqueue(_ item: CaptureItem) async {
        var updated = item
        updated.state = .uploading
        updated.updatedAt = Date()
        await persist(updated)
        await transport.enqueueUpload(id: updated.id, fileURL: store.imageURL(for: updated))
    }

    private func handle(_ completion: UploadCompletion) async {
        // Always re-read the persisted record; never trust a stale copy.
        guard var item = await store.load(id: completion.id) else { return }

        switch completion.outcome {
        case .success:
            item.state = .uploaded
            item.lastError = nil
            item.updatedAt = Date()
            await persist(item)
            log.debug("Uploaded \(item.id.uuidString, privacy: .public)")

        case let .failure(retryable, message):
            item.attemptCount += 1
            item.updatedAt = Date()
            if retryable && policy.shouldRetry(afterAttempts: item.attemptCount) {
                // Still actively being handled — keep it `uploading` and back off.
                item.state = .uploading
                item.lastError = "\(message) · retrying"
                await persist(item)
                scheduleRetry(for: item)
            } else {
                item.state = .failed
                item.lastError = message
                await persist(item)
                log.debug("Failed \(item.id.uuidString, privacy: .public): \(message, privacy: .public)")
            }
        }
    }

    private func scheduleRetry(for item: CaptureItem) {
        retryTasks[item.id]?.cancel()
        let delay = policy.delay(afterAttempts: item.attemptCount)
        let id = item.id
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fireRetry(id: id)
        }
    }

    private func fireRetry(id: UUID) async {
        retryTasks[id] = nil
        // Only re-drive if it's still awaiting upload (not reset/cancelled elsewhere).
        guard let item = await store.load(id: id), item.state == .uploading else { return }
        await transport.enqueueUpload(id: id, fileURL: store.imageURL(for: item))
    }

    private func persist(_ item: CaptureItem) async {
        try? await store.update(item)
        onItemChanged?(item)
    }
}
