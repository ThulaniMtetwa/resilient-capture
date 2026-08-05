import Foundation
import os

/// Filesystem-backed `CaptureQueueStore`.
///
/// **Layout** (under an injected root directory):
/// ```
/// <root>/images/<uuid>.jpg     ← raw capture bytes
/// <root>/items/<uuid>.json     ← metadata sidecar (state, attempts, timestamps)
/// ```
///
/// **Why per-item sidecars rather than one manifest.** Each record is independent,
/// so a write for one item can never corrupt another, and a single unreadable file
/// costs one capture instead of the whole queue. It also means concurrent updates
/// to different items don't contend on a shared file.
///
/// **Why an `actor`.** The upload manager mutates item state from background tasks
/// while the UI reads the queue. Making the store an actor serialises all access
/// without manual locks, and every file write uses `.atomic` (write-to-temp +
/// rename) so a crash mid-write leaves either the old bytes or the new - never a
/// half-written record.
actor FileCaptureQueueStore: CaptureQueueStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.iidentifii.resilientcapture", category: "store")

    private var itemsDirectory: URL { rootURL.appendingPathComponent("items", isDirectory: true) }
    private var imagesDirectory: URL { rootURL.appendingPathComponent("images", isDirectory: true) }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// The production store, rooted at `Documents/CaptureQueue`.
    static func makeDefault() -> FileCaptureQueueStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FileCaptureQueueStore(rootURL: documents.appendingPathComponent("CaptureQueue", isDirectory: true))
    }

    // MARK: - CaptureQueueStore

    @discardableResult
    func writeCapture(id: UUID, imageData: Data, createdAt: Date) async throws -> CaptureItem {
        try ensureDirectories()

        let fileName = "\(id.uuidString).jpg"
        let imageURL = imagesDirectory.appendingPathComponent(fileName)

        // 1. Persist the image bytes first, atomically. This is the point of no
        //    return for "capture completed": once these bytes are on disk the
        //    work is recoverable even if the process dies on the next line.
        try imageData.write(to: imageURL, options: [.atomic])

        // 2. Persist the metadata record marking the item `pending`. If this
        //    fails, roll back the image so we never leave an orphan behind.
        let item = CaptureItem(
            id: id,
            imageFileName: fileName,
            state: .pending,
            attemptCount: 0,
            createdAt: createdAt,
            updatedAt: createdAt,
            lastError: nil
        )
        do {
            try writeMetadata(item)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            log.error("Rolled back image for \(id.uuidString, privacy: .public) after metadata write failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        log.debug("Persisted capture \(id.uuidString, privacy: .public) as pending")
        return item
    }

    func loadAll() async throws -> [CaptureItem] {
        try ensureDirectories()
        let urls = try fileManager.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        var items: [CaptureItem] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                items.append(try decoder.decode(CaptureItem.self, from: data))
            } catch {
                // A corrupt sidecar must not sink the whole queue. Skip it and
                // keep going; the orphaned image (if any) can be recovered later.
                log.error("Skipping unreadable record \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    func load(id: UUID) async -> CaptureItem? {
        let url = itemsDirectory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CaptureItem.self, from: data)
    }

    func update(_ item: CaptureItem) async throws {
        try ensureDirectories()
        try writeMetadata(item)
    }

    func delete(id: UUID) async throws {
        let itemURL = itemsDirectory.appendingPathComponent("\(id.uuidString).json")
        let imageURL = imagesDirectory.appendingPathComponent("\(id.uuidString).jpg")
        try? fileManager.removeItem(at: itemURL)
        try? fileManager.removeItem(at: imageURL)
    }

    func imageData(for item: CaptureItem) async throws -> Data {
        try Data(contentsOf: imageURL(for: item))
    }

    nonisolated func imageURL(for item: CaptureItem) -> URL {
        // `rootURL` is immutable, so this is safe to compute without actor isolation.
        rootURL
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(item.imageFileName)
    }

    // MARK: - Private

    private func writeMetadata(_ item: CaptureItem) throws {
        let url = itemsDirectory.appendingPathComponent("\(item.id.uuidString).json")
        let data = try encoder.encode(item)
        try data.write(to: url, options: [.atomic])
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }
}
