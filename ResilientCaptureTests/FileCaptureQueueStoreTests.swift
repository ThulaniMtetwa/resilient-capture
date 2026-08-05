import XCTest
@testable import ResilientCapture

/// Tests for the persistence layer - the guarantee that a completed capture is
/// on disk before anything else happens, and survives a process restart.
final class FileCaptureQueueStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        // Each test gets its own throwaway directory so they never interfere.
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureQueueTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let rootURL, FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makeStore() -> FileCaptureQueueStore {
        FileCaptureQueueStore(rootURL: rootURL)
    }

    private func jpegData(_ byte: UInt8 = 0xAB) -> Data {
        Data(repeating: byte, count: 1024)
    }

    // MARK: - Persistence-first guarantee

    func testWriteCapturePersistsImageAndPendingMetadataImmediately() async throws {
        let store = makeStore()
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)

        let item = try await store.writeCapture(id: id, imageData: jpegData(), createdAt: createdAt)

        // Returned record is correct...
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.state, .pending)
        XCTAssertEqual(item.attemptCount, 0)
        XCTAssertNil(item.lastError)

        // ...and both the image bytes and the metadata are already on disk,
        // before any network call could have run.
        let imageExists = FileManager.default.fileExists(atPath: store.imageURL(for: item).path)
        XCTAssertTrue(imageExists, "Image bytes must be persisted synchronously on capture")

        let reloaded = try await store.loadAll()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.state, .pending)
    }

    func testCapturedImageBytesRoundTrip() async throws {
        let store = makeStore()
        let bytes = jpegData(0x42)
        let item = try await store.writeCapture(id: UUID(), imageData: bytes, createdAt: Date())

        let readBack = try await store.imageData(for: item)
        XCTAssertEqual(readBack, bytes, "The exact captured bytes must survive the round-trip")
    }

    // MARK: - Survives relaunch (new store instance, same directory)

    func testQueueSurvivesProcessRestart() async throws {
        let firstLaunch = makeStore()
        let id = UUID()
        try await firstLaunch.writeCapture(id: id, imageData: jpegData(), createdAt: Date())

        // Simulate a full relaunch: a brand-new store object over the same directory,
        // with no shared in-memory state.
        let secondLaunch = makeStore()
        let items = try await secondLaunch.loadAll()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, id)
        XCTAssertEqual(items.first?.state, .pending)
    }

    // MARK: - State transitions persist

    func testUpdatePersistsNewState() async throws {
        let store = makeStore()
        var item = try await store.writeCapture(id: UUID(), imageData: jpegData(), createdAt: Date())

        item.state = .uploaded
        item.attemptCount = 2
        item.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await store.update(item)

        // Reload from a fresh instance to prove it hit disk, not just memory.
        let reloaded = try await makeStore().loadAll()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.state, .uploaded)
        XCTAssertEqual(reloaded.first?.attemptCount, 2)
    }

    func testUpdateIsUpsertNotDuplicate() async throws {
        let store = makeStore()
        let id = UUID()
        var item = try await store.writeCapture(id: id, imageData: jpegData(), createdAt: Date())

        item.state = .failed
        try await store.update(item)
        item.state = .uploading
        try await store.update(item)

        let items = try await store.loadAll()
        XCTAssertEqual(items.count, 1, "Repeated updates to the same id must not create duplicates")
        XCTAssertEqual(items.first?.state, .uploading)
    }

    // MARK: - Deletion

    func testDeleteRemovesMetadataAndImage() async throws {
        let store = makeStore()
        let item = try await store.writeCapture(id: UUID(), imageData: jpegData(), createdAt: Date())
        let imagePath = store.imageURL(for: item).path

        try await store.delete(id: item.id)

        let items = try await store.loadAll()
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath), "Image bytes must be removed on delete")
    }

    // MARK: - Ordering and robustness

    func testLoadAllReturnsItemsOldestFirst() async throws {
        let store = makeStore()
        let older = try await store.writeCapture(id: UUID(), imageData: jpegData(), createdAt: Date(timeIntervalSince1970: 100))
        let newer = try await store.writeCapture(id: UUID(), imageData: jpegData(), createdAt: Date(timeIntervalSince1970: 200))

        let items = try await store.loadAll()
        XCTAssertEqual(items.map(\.id), [older.id, newer.id])
    }

    func testCorruptRecordIsSkippedNotFatal() async throws {
        let store = makeStore()
        let good = try await store.writeCapture(id: UUID(), imageData: jpegData(), createdAt: Date())

        // Write a garbage sidecar directly into the items directory.
        let itemsDir = rootURL.appendingPathComponent("items", isDirectory: true)
        let corruptURL = itemsDir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: corruptURL)

        let items = try await store.loadAll()
        XCTAssertEqual(items.map(\.id), [good.id], "A corrupt record is skipped; the good one still loads")
    }

    func testLoadAllOnEmptyStoreReturnsEmpty() async throws {
        let items = try await makeStore().loadAll()
        XCTAssertTrue(items.isEmpty)
    }
}
