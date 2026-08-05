import Foundation
import os

/// Production `UploadTransport` backed by a **background** `URLSession`.
///
/// Why background configuration: the OS owns the transfer, so uploads keep going
/// while the app is suspended, and the session is re-attachable across launches
/// via its identifier. Background sessions must upload **from a file** (not an
/// in-memory body) — which fits perfectly, because every capture is already a
/// file on disk from Step 1.
///
/// Completions are delivered by the `URLSession` delegate (on a private queue)
/// and forwarded onto an `AsyncStream` the `UploadManager` consumes. State that
/// matters for correctness lives in the durable store, not here, so a delegate
/// callback that arrives after relaunch still lands on the right record.
///
/// `@unchecked Sendable`: the only mutable state is the stream continuation and
/// the app-provided background-events handler, both guarded by `lock`.
final class BackgroundUploadTransport: NSObject, UploadTransport, @unchecked Sendable {
    private let endpoint: URL
    private let sessionIdentifier: String
    private let lock = NSLock()
    private var continuation: AsyncStream<UploadCompletion>.Continuation?
    private let log = Logger(subsystem: "com.iidentifii.resilientcapture", category: "upload")

    /// Set by the app delegate when iOS wakes the app to finish background events;
    /// invoked (and cleared) once the session reports it has flushed them.
    var backgroundEventsHandler: (@Sendable () -> Void)?

    private lazy var session: URLSession = {
        let config: URLSessionConfiguration
        #if targetEnvironment(simulator)
        // The background transfer daemon (nsurlsessiond) is not functional in the
        // iOS Simulator — background tasks fail immediately with NSURLErrorUnknown
        // (-1). Use a standard configuration here. This does NOT weaken the
        // resilience guarantees for our scenarios: durability comes from the
        // persist-first store + launch reconciliation + server idempotency, not
        // from the OS continuing a suspended transfer. Kill/relaunch/connectivity
        // all behave identically. On a real device the #else branch is a true
        // background session that additionally continues uploads while suspended.
        config = URLSessionConfiguration.default
        #else
        config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false            // upload promptly, don't wait for "ideal" conditions
        config.sessionSendsLaunchEvents = true     // relaunch the app to deliver completions
        #endif
        config.allowsCellularAccess = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    init(endpoint: URL, sessionIdentifier: String = "com.iidentifii.resilientcapture.upload") {
        self.endpoint = endpoint
        self.sessionIdentifier = sessionIdentifier
        super.init()
    }

    // MARK: - UploadTransport

    func makeOutcomeStream() -> AsyncStream<UploadCompletion> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
            // Touch `session` so it's created and starts delivering delegate
            // callbacks for any tasks the OS resumed from a previous launch.
            _ = session
        }
    }

    func enqueueUpload(id: UUID, fileURL: URL) async {
        // Idempotent per id: if the OS is already carrying this upload, don't add
        // a second task for it.
        if await inFlightIDs().contains(id) {
            log.debug("Skip enqueue \(id.uuidString, privacy: .public): already in flight")
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(id.uuidString, forHTTPHeaderField: "X-Capture-Id")

        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = id.uuidString   // lets us map completions back to the record
        task.resume()
        log.debug("Enqueued upload \(id.uuidString, privacy: .public)")
    }

    func inFlightIDs() async -> Set<UUID> {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                let ids = tasks.compactMap { $0.taskDescription.flatMap(UUID.init) }
                cont.resume(returning: Set(ids))
            }
        }
    }

    private func emit(_ completion: UploadCompletion) {
        let cont = lock.withLock { continuation }
        cont?.yield(completion)
    }
}

// MARK: - URLSessionDataDelegate

extension BackgroundUploadTransport: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init) else { return }
        let outcome = Self.outcome(for: task, error: error)
        log.debug("Completion \(id.uuidString, privacy: .public): \(String(describing: outcome), privacy: .public)")
        emit(UploadCompletion(id: id, outcome: outcome))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // iOS woke us just to flush background completions; tell UIKit we're done
        // so it can snapshot and suspend again.
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            let h = backgroundEventsHandler
            backgroundEventsHandler = nil
            return h
        }
        if let handler {
            DispatchQueue.main.async { handler() }
        }
    }

    /// Map a finished task to an outcome. Retryable = transient (network error,
    /// timeout, 408/429/5xx); non-retryable = a 4xx the server will keep rejecting.
    static func outcome(for task: URLSessionTask, error: Error?) -> UploadOutcome {
        if let error {
            return .failure(retryable: true, message: error.localizedDescription)
        }
        guard let http = task.response as? HTTPURLResponse else {
            return .failure(retryable: true, message: "No HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return .success
        case 408, 429, 500...599:
            return .failure(retryable: true, message: "HTTP \(http.statusCode)")
        default:
            return .failure(retryable: false, message: "HTTP \(http.statusCode)")
        }
    }
}
