import Foundation

/// The **network seam**: how the queue actually pushes bytes to the backend.
///
/// Abstracted so `UploadManager`'s orchestration (selection, state transitions,
/// retry/backoff, reconciliation) can be unit-tested against a deterministic fake
/// with no real networking, while production uses a background `URLSession`.
///
/// The contract is deliberately fire-and-forget: `enqueueUpload` starts an upload
/// and returns; results arrive later on the outcome stream. This matches how a
/// background session behaves - a completion can be delivered minutes later, or
/// even after the app has been relaunched.
protocol UploadTransport: Sendable {
    /// Create the single stream of upload outcomes. Called once by the manager
    /// before it enqueues anything; the manager is the sole consumer.
    func makeOutcomeStream() -> AsyncStream<UploadCompletion>

    /// Begin (or resume) uploading the file at `fileURL` for capture `id`.
    /// Idempotent per id: enqueuing an id that's already in flight is a no-op.
    func enqueueUpload(id: UUID, fileURL: URL) async

    /// Capture ids the transport currently has in flight. Used on launch to
    /// reconcile persisted `uploading` items against reality without re-uploading
    /// something the OS is still delivering.
    func inFlightIDs() async -> Set<UUID>
}
