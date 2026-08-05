import Foundation

/// The result of a single upload attempt, as reported by the transport.
///
/// `retryable` distinguishes transient failures (network drop, 5xx, timeout)
/// that should be retried from permanent ones (4xx client errors) that never
/// will succeed by retrying, so the manager doesn't spin forever on a bad request.
enum UploadOutcome: Sendable, Equatable {
    case success
    case failure(retryable: Bool, message: String)
}

/// A completed upload: which capture, and how it went. Emitted by the transport's
/// outcome stream - possibly long after the attempt began (e.g. after relaunch,
/// for a background transport).
struct UploadCompletion: Sendable, Equatable {
    let id: UUID
    let outcome: UploadOutcome
}
