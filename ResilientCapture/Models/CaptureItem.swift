import Foundation

/// The lifecycle of a single capture as it moves through the upload pipeline.
///
/// Modelled as one enum rather than parallel `isUploading` / `didFail` booleans
/// so that impossible states (e.g. "uploaded AND failed") cannot be represented.
enum UploadState: String, Codable, Sendable, CaseIterable {
    /// Persisted to disk, not yet handed to the network. The state every
    /// capture is born in — set *before* any upload is attempted.
    case pending
    /// Handed to the upload transport; awaiting a confirmed server response.
    case uploading
    /// The backend confirmed receipt (2xx). Terminal, success.
    case uploaded
    /// The last attempt failed. Eligible for automatic or manual retry.
    case failed

    /// Whether an item in this state should be (re)attempted by the upload manager.
    var isUploadable: Bool {
        switch self {
        case .pending, .failed: return true
        case .uploading, .uploaded: return false
        }
    }
}

/// One item in the durable upload queue.
///
/// This is the metadata record persisted alongside the image bytes. `id` doubles
/// as the **idempotency key**: it is generated once on capture, sent with every
/// upload attempt, and lets the backend collapse duplicate deliveries so a retry
/// can never create a second verification.
struct CaptureItem: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity + idempotency key. Generated at capture time, never reused.
    let id: UUID
    /// Filename of the image bytes on disk, relative to the store's images directory.
    let imageFileName: String
    /// Current position in the upload lifecycle.
    var state: UploadState
    /// Number of upload attempts made so far. Drives exponential backoff.
    var attemptCount: Int
    /// When the capture was taken (used for stable, chronological ordering).
    let createdAt: Date
    /// When this record was last written. Bumped on every state transition.
    var updatedAt: Date
    /// Human-readable description of the most recent failure, for the UI.
    var lastError: String?

    init(
        id: UUID,
        imageFileName: String,
        state: UploadState = .pending,
        attemptCount: Int = 0,
        createdAt: Date,
        updatedAt: Date,
        lastError: String? = nil
    ) {
        self.id = id
        self.imageFileName = imageFileName
        self.state = state
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}
