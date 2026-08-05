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
///
/// Image bytes are stored **encrypted at rest**. Because a background upload must
/// send from a file, the store also vends a short-lived *decrypted* temp file for
/// the transport (`makeDecryptedUploadFile`), which the caller discards once the
/// upload finishes.
protocol CaptureQueueStore: Sendable {
    /// Atomically persist a freshly captured image (encrypted) and its metadata
    /// as `pending`. Writes the image first, then the metadata; on metadata
    /// failure the image is rolled back so no orphan is left behind.
    @discardableResult
    func writeCapture(id: UUID, imageData: Data, createdAt: Date) async throws -> CaptureItem

    /// Load every persisted item, oldest first. Corrupt records are skipped.
    func loadAll() async throws -> [CaptureItem]

    /// Load a single record by id, or `nil` if missing/unreadable.
    func load(id: UUID) async -> CaptureItem?

    /// Upsert an item's metadata (same `id` overwrites). Atomic per record.
    func update(_ item: CaptureItem) async throws

    /// Remove an item's metadata and its image bytes.
    func delete(id: UUID) async throws

    /// The **decrypted** image bytes for an item (used to render thumbnails).
    /// Returns `nil` if the image has been minimised away after upload.
    func imageData(for item: CaptureItem) async -> Data?

    /// Write the decrypted image to a short-lived, Data-Protected temp file and
    /// return its URL, for the transport to upload from. Caller must call
    /// `discardUploadFile` once the upload finishes.
    func makeDecryptedUploadFile(for item: CaptureItem) async throws -> URL

    /// Delete a temp upload file created by `makeDecryptedUploadFile`.
    func discardUploadFile(at url: URL) async

    /// Delete only the (encrypted) image bytes for an item, keeping its metadata
    /// record as a receipt. Used to minimise data once an upload is confirmed.
    func discardCaptureImage(for id: UUID) async

    /// Remove any leftover decrypted temp files (e.g. from a previous launch that
    /// was killed mid-upload). Call once at startup.
    func purgeUploadTemp() async
}
