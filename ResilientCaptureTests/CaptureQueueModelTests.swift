import XCTest
@testable import ResilientCapture

/// Tests for `CaptureQueueModel.remove(id:)`.
///
/// Uses a real `FileCaptureQueueStore` (temp dir) so the encrypted-file purge is
/// actually exercised, a `FakeUploadTransport` so uploads are deterministic, and a
/// `ScriptedConnectivityMonitor` for the connectivity seam. The transport's
/// `handler` is left `nil`, so an enqueued capture stays in flight (no completion
/// arrives) and the queue state is stable while we assert removal.
@MainActor
final class CaptureQueueModelTests: XCTestCase {
    private var rootURL: URL!
    private var store: FileCaptureQueueStore!
    private var transport: FakeUploadTransport!
    private var connectivity: ScriptedConnectivityMonitor!

    private let fastPolicy = RetryPolicy(baseDelay: 0.01, multiplier: 2, maxDelay: 0.05, maxAttempts: 3, jitter: 0)

    override func setUp() async throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueModelTests-\(UUID().uuidString)", isDirectory: true)
        store = FileCaptureQueueStore(rootURL: rootURL, crypto: TestCrypto.make())
        transport = FakeUploadTransport()
        connectivity = ScriptedConnectivityMonitor(initial: .unknownOnline)
    }

    override func tearDown() async throws {
        connectivity?.cancel()
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - Helpers

    private func makeModel() -> CaptureQueueModel {
        CaptureQueueModel(store: store, transport: transport, connectivity: connectivity, policy: fastPolicy)
    }

    private func jpeg() -> Data { Data(repeating: 0xAB, count: 64) }

    // MARK: - remove()

    func testRemovePurgesRecordImageAndRow() async throws {
        let model = makeModel()
        await model.start()
        await model.enqueue(imageData: jpeg())

        let item = try XCTUnwrap(model.items.first, "enqueue should have added a row")
        // Precondition: the encrypted capture is on disk before removal.
        let imageBefore = await store.imageData(for: item)
        XCTAssertNotNil(imageBefore, "capture bytes should exist before removal")

        await model.remove(id: item.id)

        XCTAssertTrue(model.items.isEmpty, "the row is dropped from the visible queue")
        let record = await store.load(id: item.id)
        XCTAssertNil(record, "the metadata record is purged from disk")
        let imageAfter = await store.imageData(for: item)
        XCTAssertNil(imageAfter, "the encrypted image bytes are purged from disk")
    }

    func testRemoveOnlyAffectsTargetedItem() async throws {
        let model = makeModel()
        await model.start()
        await model.enqueue(imageData: jpeg())
        await model.enqueue(imageData: jpeg())
        XCTAssertEqual(model.items.count, 2, "two captures enqueued")

        let target = try XCTUnwrap(model.items.first)
        let survivor = try XCTUnwrap(model.items.last)

        await model.remove(id: target.id)

        XCTAssertEqual(model.items.map(\.id), [survivor.id], "only the survivor remains in the queue")
        let removed = await store.load(id: target.id)
        XCTAssertNil(removed, "the targeted record is gone")
        let kept = await store.load(id: survivor.id)
        XCTAssertNotNil(kept, "the other capture is untouched on disk")
    }

    func testRemoveIsSafeIfUploadCompletesAfterward() async throws {
        // Leave the upload in flight so we can complete it AFTER removal, simulating
        // the OS reporting a background upload as finished for an item the user has
        // already deleted. The manager must re-read the store, find nothing, and
        // no-op, so the capture never reappears.
        transport.handler = { _, _ in nil }

        let model = makeModel()
        await model.start()
        await model.enqueue(imageData: jpeg())
        let item = try XCTUnwrap(model.items.first)

        await model.remove(id: item.id)
        XCTAssertTrue(model.items.isEmpty, "row removed")

        transport.complete(item.id, .success)
        // Give the manager's outcome-consumer a beat to (not) act.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(model.items.isEmpty, "a late completion must not resurrect a removed capture")
        let record = await store.load(id: item.id)
        XCTAssertNil(record, "the record stays purged after a late completion")
    }
}
