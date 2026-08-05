import Foundation
import os

/// Filesystem-backed `CaptureQueueStore` with encryption at rest.
///
/// **Layout** (under an injected root directory):
/// ```
/// <root>/images/<uuid>.enc      AES-GCM ciphertext of the capture bytes
/// <root>/items/<uuid>.json      metadata sidecar (no PII: id, state, timestamps)
/// <root>/uploads/<uuid>.jpg     transient DECRYPTED file for an in-flight upload
/// ```
///
/// **Security posture.** Image bytes are encrypted with `CaptureCrypto` before
/// they ever touch disk, so the persisted `.enc` files are ciphertext. Metadata
/// is left in clear text because it holds no PII (a random UUID, a state, and
/// timestamps). All writes additionally carry iOS Data Protection
/// (`completeUntilFirstUserAuthentication`) and the queue directory is excluded
/// from iCloud/iTunes backup. Decryption to a temp file happens only for the
/// brief window of an active upload, and that directory is purged on launch.
///
/// **Why an `actor`.** The upload manager mutates item state from background
/// tasks while the UI reads the queue. Serialising through an actor removes races
/// without manual locks; every write is `.atomic` (write-temp + rename).
actor FileCaptureQueueStore: CaptureQueueStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private let crypto: CaptureCrypto
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.iidentifii.resilientcapture", category: "store")

    private var itemsDirectory: URL { rootURL.appendingPathComponent("items", isDirectory: true) }
    private var imagesDirectory: URL { rootURL.appendingPathComponent("images", isDirectory: true) }
    private var uploadsDirectory: URL { rootURL.appendingPathComponent("uploads", isDirectory: true) }

    /// Data Protection class applied to every write. `completeUntilFirstUserAuthentication`
    /// keeps files encrypted until the first unlock after boot, then readable for
    /// background work (including while the screen is locked), which the
    /// background-upload use case requires. Stricter `.complete` would block
    /// locked-state uploads.
    private let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    init(rootURL: URL, crypto: CaptureCrypto, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.crypto = crypto
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// The production store, rooted at `Documents/CaptureQueue`, keyed from the
    /// Keychain (with a protected key-file fallback for unsigned builds).
    static func makeDefault() -> FileCaptureQueueStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("CaptureQueue", isDirectory: true)
        let key = CaptureKeyProvider.loadOrCreateKey(rootURL: root)
        return FileCaptureQueueStore(rootURL: root, crypto: CaptureCrypto(key: key))
    }

    // MARK: - CaptureQueueStore

    @discardableResult
    func writeCapture(id: UUID, imageData: Data, createdAt: Date) async throws -> CaptureItem {
        try ensureDirectories()

        let fileName = "\(id.uuidString).enc"
        let imageURL = imagesDirectory.appendingPathComponent(fileName)

        // 1. Encrypt, then persist the ciphertext first, atomically. Once these
        //    bytes are on disk the capture is recoverable even if we die next line.
        let ciphertext = try crypto.seal(imageData)
        try ciphertext.write(to: imageURL, options: writeOptions)

        // 2. Persist the metadata record marking the item `pending`. On failure,
        //    roll back the image so we never leave an orphan behind.
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
            log.error("Rolled back image for \(id.uuidString, privacy: .public) after metadata write failed")
            throw error
        }
        return item
    }

    func loadAll() async throws -> [CaptureItem] {
        try ensureDirectories()
        let urls = try fileManager.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var items: [CaptureItem] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                items.append(try decoder.decode(CaptureItem.self, from: data))
            } catch {
                log.error("Skipping unreadable record \(url.lastPathComponent, privacy: .public)")
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
        try? fileManager.removeItem(at: itemsDirectory.appendingPathComponent("\(id.uuidString).json"))
        try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent("\(id.uuidString).enc"))
    }

    func imageData(for item: CaptureItem) async -> Data? {
        let url = imagesDirectory.appendingPathComponent(item.imageFileName)
        guard let ciphertext = try? Data(contentsOf: url) else { return nil }
        return try? crypto.open(ciphertext)
    }

    func makeDecryptedUploadFile(for item: CaptureItem) async throws -> URL {
        try ensureDirectories()
        let ciphertext = try Data(contentsOf: imagesDirectory.appendingPathComponent(item.imageFileName))
        let plaintext = try crypto.open(ciphertext)
        let url = uploadsDirectory.appendingPathComponent("\(item.id.uuidString).jpg")
        try plaintext.write(to: url, options: writeOptions)
        return url
    }

    func discardUploadFile(at url: URL) async {
        try? fileManager.removeItem(at: url)
    }

    func discardCaptureImage(for id: UUID) async {
        try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent("\(id.uuidString).enc"))
    }

    func purgeUploadTemp() async {
        guard let contents = try? fileManager.contentsOfDirectory(at: uploadsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents { try? fileManager.removeItem(at: url) }
    }

    // MARK: - Private

    private func writeMetadata(_ item: CaptureItem) throws {
        let url = itemsDirectory.appendingPathComponent("\(item.id.uuidString).json")
        let data = try encoder.encode(item)
        try data.write(to: url, options: writeOptions)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
        excludeRootFromBackup()
    }

    /// Keep identity images out of iCloud/iTunes backups.
    private func excludeRootFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = rootURL
        try? url.setResourceValues(values)
    }
}
