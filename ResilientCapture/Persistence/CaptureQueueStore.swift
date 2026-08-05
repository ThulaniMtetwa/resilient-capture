import Foundation

/// Durable storage for the capture queue.
///
/// This is the **disk seam**: the one place with an uncontrollable side effect
/// (the filesystem), so it is expressed as a protocol and injected. Tests
/// substitute a store rooted in a temporary directory; production points it at
/// `Documents/`. Callers depend on this protocol, never on `FileManager` directly.
///
/// The contract that makes the pipeline resilient lives in `writeCapture`:
/// image bytes and a `pending` metadata record must both be on disk *before the
/// method returns* and *before any network call is made*, so a crash at any later
/// point can never lose a completed capture.
protocol CaptureQueueStore: Sendable {
    /// Atomically persist a freshly captured image and its metadata as `pending`.
    ///
    /// Writes the image bytes first, then the metadata record. If the metadata
    /// write fails the image is rolled back so no orphan is left behind. Returns
    /// the persisted item so the caller never fabricates state the disk doesn't have.
    @discardableResult
    func writeCapture(id: UUID, imageData: Data, createdAt: Date) async throws -> CaptureItem

    /// Load every persisted item, oldest first. Corrupt records are skipped, not
    /// fatal, so one bad sidecar can't sink the whole queue on launch.
    func loadAll() async throws -> [CaptureItem]

    /// Load a single record by id, or `nil` if it's missing/unreadable. Used by
    /// the upload manager to re-read an item's current persisted state before a
    /// transition (never trusting stale in-memory copies).
    func load(id: UUID) async -> CaptureItem?

    /// Upsert an item's metadata (same `id` overwrites). Atomic per record.
    func update(_ item: CaptureItem) async throws

    /// Remove an item's metadata and its image bytes.
    func delete(id: UUID) async throws

    /// Read the image bytes for an item (used by the uploader).
    func imageData(for item: CaptureItem) async throws -> Data

    /// The on-disk location of an item's image (used by the UI to render thumbnails).
    func imageURL(for item: CaptureItem) -> URL
}
