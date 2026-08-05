import XCTest
@testable import ResilientCapture

/// Tests for the pure backoff math. Deterministic via an injected RNG.
final class RetryPolicyTests: XCTestCase {
    private let policy = RetryPolicy(baseDelay: 1, multiplier: 2, maxDelay: 30, maxAttempts: 5, jitter: 0.2)

    func testFirstRetryUsesBaseDelay() {
        // No jitter (RNG returns 0) → exactly baseDelay.
        let delay = policy.delay(afterAttempts: 1, random: { _ in 0 })
        XCTAssertEqual(delay, 1, accuracy: 0.0001)
    }

    func testBackoffGrowsExponentially() {
        let d1 = policy.delay(afterAttempts: 1, random: { _ in 0 })
        let d2 = policy.delay(afterAttempts: 2, random: { _ in 0 })
        let d3 = policy.delay(afterAttempts: 3, random: { _ in 0 })
        XCTAssertEqual(d1, 1, accuracy: 0.0001)
        XCTAssertEqual(d2, 2, accuracy: 0.0001)
        XCTAssertEqual(d3, 4, accuracy: 0.0001)
    }

    func testBackoffIsCappedAtMaxDelay() {
        // Attempt 10 would be 2^9 = 512s without a cap.
        let delay = policy.delay(afterAttempts: 10, random: { _ in 0 })
        XCTAssertEqual(delay, 30, accuracy: 0.0001)
    }

    func testJitterStaysWithinBounds() {
        // RNG at the extremes of ±jitter yields the widest spread.
        let low = policy.delay(afterAttempts: 3, random: { range in range.lowerBound })
        let high = policy.delay(afterAttempts: 3, random: { range in range.upperBound })
        XCTAssertEqual(low, 4 * 0.8, accuracy: 0.0001)   // -20%
        XCTAssertEqual(high, 4 * 1.2, accuracy: 0.0001)  // +20%
    }

    func testShouldRetryRespectsMaxAttempts() {
        XCTAssertTrue(policy.shouldRetry(afterAttempts: 4))
        XCTAssertFalse(policy.shouldRetry(afterAttempts: 5))
        XCTAssertFalse(policy.shouldRetry(afterAttempts: 6))
    }
}
