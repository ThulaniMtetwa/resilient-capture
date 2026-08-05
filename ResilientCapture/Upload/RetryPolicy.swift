import Foundation

/// Exponential-backoff-with-jitter policy for failed uploads.
///
/// Pure value type with no side effects, so it needs no protocol and is trivially
/// unit-tested. `delay(forAttempt:)` takes an injectable RNG so tests can assert
/// exact, deterministic bounds.
struct RetryPolicy: Sendable, Equatable {
    /// Delay before the first retry.
    var baseDelay: TimeInterval = 1
    /// Growth factor per attempt.
    var multiplier: Double = 2
    /// Ceiling so backoff never grows unbounded.
    var maxDelay: TimeInterval = 60
    /// Total attempts before giving up and marking the item `failed`.
    var maxAttempts: Int = 6
    /// Fractional jitter (±). 0.2 = ±20%, spreading retries so a fleet of
    /// devices doesn't stampede the backend in lockstep after an outage.
    var jitter: Double = 0.2

    /// Whether another attempt is allowed given how many have already been made.
    func shouldRetry(afterAttempts attemptsMade: Int) -> Bool {
        attemptsMade < maxAttempts
    }

    /// Backoff before the next attempt. `attemptsMade` is the number of attempts
    /// already completed (≥1 after the first failure). The RNG is injectable for
    /// deterministic tests; it returns a value in the given closed range.
    func delay(
        afterAttempts attemptsMade: Int,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let exponent = Double(max(0, attemptsMade - 1))
        let raw = baseDelay * pow(multiplier, exponent)
        let capped = min(raw, maxDelay)
        let jitterFactor = 1 + random(-jitter...jitter)
        return max(0, capped * jitterFactor)
    }
}
