import XCTest
@testable import ResilientCapture

/// Tests for the retry/resume orchestration. Uses a real `FileCaptureQueueStore`
/// (temp dir) so persistence is exercised too, and a `FakeUploadTransport` so
/// outcomes are deterministic. Backoff is tiny so retries happen fast.
@MainActor
final class UploadManagerTests: XCTestCase {
    private var rootURL: URL!
    private var store: FileCaptureQueueStore!
    private var transport: FakeUploadTransport!
    private var manager: UploadManager!

    private let fastPolicy = RetryPolicy(baseDelay: 0.01, multiplier: 2, maxDelay: 0.05, maxAttempts: 3, jitter: 0)

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MgrTests-\(UUID().uuidString)", isDirectory: true)
        store = FileCaptureQueueStore(rootURL: rootURL)
        transport = FakeUploadTransport()
        manager = UploadManager(store: store, transport: transport, policy: fastPolicy)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - Helpers

    private func jpeg() -> Data { Data(repeating: 0xAB, count: 64) }

    @discardableResult
    private func makePending() async throws -> CaptureItem {
        try await store.writeCapture(id: UUID(), imageData: jpeg(), createdAt: Date())
    }

    /// Poll until `condition` holds or time out.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    private func state(of id: UUID) async -> UploadState? {
        await store.load(id: id)?.state
    }

    // MARK: - Happy path

    func testSuccessMarksUploaded() async throws {
        transport.handler = { _, _ in .success }
        manager.start()
        let item = try await makePending()

        await manager.enqueueNew(item)

        await waitUntil("uploaded") { await self.state(of: item.id) == .uploaded }
        XCTAssertEqual(transport.enqueueCount(for: item.id), 1)
    }

    // MARK: - Retry then success (the core retry/resume behaviour)

    func testRetryableFailureThenSuccess() async throws {
        // Fail the first attempt, succeed on the second.
        transport.handler = { _, attempt in attempt < 2 ? .failure(retryable: true, message: "500") : .success }
        manager.start()
        let item = try await makePending()

        await manager.enqueueNew(item)

        await waitUntil("uploaded after retry") { await self.state(of: item.id) == .uploaded }
        XCTAssertEqual(transport.enqueueCount(for: item.id), 2, "One failure + one success = two attempts")
        let final = await store.load(id: item.id)
        XCTAssertEqual(final?.attemptCount, 1, "Manager counts the single failure")
    }

    func testStaysUploadingWhileRetrying() async throws {
        // First attempt fails; hold the second in flight so we can observe the
        // interim state (must be `uploading`, not `failed`).
        transport.handler = { _, attempt in attempt < 2 ? .failure(retryable: true, message: "503") : nil }
        manager.start()
        let item = try await makePending()

        await manager.enqueueNew(item)

        await waitUntil("re-enqueued") { self.transport.enqueueCount(for: item.id) == 2 }
        let interim = await state(of: item.id)
        XCTAssertEqual(interim, .uploading, "Auto-retry keeps the item uploading, never failed")
    }

    // MARK: - Exhaustion & permanent failure

    func testExhaustsRetriesThenFailed() async throws {
        transport.handler = { _, _ in .failure(retryable: true, message: "always 500") }
        manager.start()
        let item = try await makePending()

        await manager.enqueueNew(item)

        await waitUntil("failed after exhaustion") { await self.state(of: item.id) == .failed }
        XCTAssertEqual(transport.enqueueCount(for: item.id), fastPolicy.maxAttempts, "Tried exactly maxAttempts times")
        let final = await store.load(id: item.id)
        XCTAssertEqual(final?.attemptCount, fastPolicy.maxAttempts)
    }

    func testNonRetryableFailsImmediately() async throws {
        transport.handler = { _, _ in .failure(retryable: false, message: "HTTP 400") }
        manager.start()
        let item = try await makePending()

        await manager.enqueueNew(item)

        await waitUntil("failed immediately") { await self.state(of: item.id) == .failed }
        XCTAssertEqual(transport.enqueueCount(for: item.id), 1, "A 4xx is never retried")
        let final = await store.load(id: item.id)
        XCTAssertEqual(final?.lastError, "HTTP 400")
    }

    // MARK: - Manual retry

    func testManualRetryResetsAndReuploads() async throws {
        // Start permanently failing, then flip to success and manually retry.
        var succeed = false
        transport.handler = { _, _ in succeed ? .success : .failure(retryable: false, message: "HTTP 400") }
        manager.start()
        let item = try await makePending()

        await manager.enqueueNew(item)
        await waitUntil("failed first") { await self.state(of: item.id) == .failed }

        succeed = true
        await manager.retry(id: item.id)

        await waitUntil("uploaded after manual retry") { await self.state(of: item.id) == .uploaded }
        let final = await store.load(id: item.id)
        XCTAssertEqual(final?.attemptCount, 0, "Manual retry resets the attempt budget")
        XCTAssertNil(final?.lastError)
    }

    // MARK: - Resume / reconciliation (kill mid-upload)

    func testResumeReenqueuesStaleUploading() async throws {
        // Simulate a kill mid-upload: an item persisted as `uploading` that the
        // transport is NOT carrying. resume() must re-drive it.
        var item = try await makePending()
        item.state = .uploading
        try await store.update(item)

        transport.handler = { _, _ in .success }
        manager.start()
        await manager.resume()

        await waitUntil("stale uploading re-driven to uploaded") { await self.state(of: item.id) == .uploaded }
        XCTAssertGreaterThanOrEqual(transport.enqueueCount(for: item.id), 1)
    }

    func testResumeDoesNotDuplicateInFlightUpload() async throws {
        // An item is `uploading` AND the transport still has it in flight.
        // resume() must NOT enqueue it again (no duplicate upload).
        var item = try await makePending()
        item.state = .uploading
        try await store.update(item)
        transport.presetInFlight(item.id)
        transport.handler = { _, _ in .success }

        manager.start()
        await manager.resume()
        // Give resume a beat to (not) act.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(transport.enqueueCount(for: item.id), 0, "In-flight item must not be re-enqueued")
    }

    func testResumeEnqueuesPending() async throws {
        transport.handler = { _, _ in .success }
        let item = try await makePending()   // pending, never enqueued yet

        manager.start()
        await manager.resume()

        await waitUntil("pending picked up by resume") { await self.state(of: item.id) == .uploaded }
    }

    // MARK: - Connectivity

    func testOfflineKeepsPendingThenUploadsOnReconnect() async throws {
        transport.handler = { _, _ in .success }
        manager.start()
        await manager.connectivityChanged(to: .offline)

        let item = try await makePending()
        await manager.enqueueNew(item)

        // While offline: stays pending, never handed to the transport.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let offlineState = await state(of: item.id)
        XCTAssertEqual(offlineState, .pending)
        XCTAssertEqual(transport.enqueueCount(for: item.id), 0)

        // Reconnect → auto-resume → uploaded.
        await manager.connectivityChanged(to: .unknownOnline)
        await waitUntil("uploaded after reconnect") { await self.state(of: item.id) == .uploaded }
    }
}
