import Foundation
@testable import ResilientCapture

/// A deterministic `UploadTransport` for tests. No networking: a `handler`
/// closure decides each attempt's outcome, so retry/resume behaviour can be
/// driven precisely and synchronously.
///
/// `@unchecked Sendable`: mutable state guarded by `lock`.
final class FakeUploadTransport: UploadTransport, @unchecked Sendable {
    /// Decide the outcome for an enqueue. `attempt` is the per-id attempt count
    /// (1-based). Return `nil` to leave the upload "in flight" (simulating a
    /// hung/suspended task that never completes) - the test can finish it later
    /// with `complete(_:_:)`.
    var handler: (@Sendable (_ id: UUID, _ attempt: Int) -> UploadOutcome?)?

    private let lock = NSLock()
    private var continuation: AsyncStream<UploadCompletion>.Continuation?
    private var inFlight: Set<UUID> = []
    private var attempts: [UUID: Int] = [:]
    /// Every id ever handed to `enqueueUpload`, in order (for asserting retries).
    private(set) var enqueuedIDs: [UUID] = []

    // MARK: UploadTransport

    func makeOutcomeStream() -> AsyncStream<UploadCompletion> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func enqueueUpload(id: UUID, fileURL: URL) async {
        let attempt: Int = lock.withLock {
            enqueuedIDs.append(id)
            inFlight.insert(id)
            attempts[id, default: 0] += 1
            return attempts[id]!
        }
        if let outcome = handler?(id, attempt) {
            lock.withLock { _ = inFlight.remove(id) }
            emit(UploadCompletion(id: id, outcome: outcome))
        }
        // else: leave in flight; test drives completion via complete(_:_:)
    }

    func inFlightIDs() async -> Set<UUID> {
        lock.withLock { inFlight }
    }

    // MARK: Test controls

    /// Number of times a given id was enqueued.
    func enqueueCount(for id: UUID) -> Int {
        lock.withLock { enqueuedIDs.filter { $0 == id }.count }
    }

    /// Pretend the transport is already carrying `id` (as if the OS resumed it).
    func presetInFlight(_ id: UUID) {
        lock.withLock { _ = inFlight.insert(id) }
    }

    /// Complete an in-flight upload with a specific outcome.
    func complete(_ id: UUID, _ outcome: UploadOutcome) {
        lock.withLock { _ = inFlight.remove(id) }
        emit(UploadCompletion(id: id, outcome: outcome))
    }

    private func emit(_ completion: UploadCompletion) {
        let cont = lock.withLock { continuation }
        cont?.yield(completion)
    }
}
