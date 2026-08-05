import Foundation

/// A `ConnectivityMonitor` whose status is set programmatically.
///
/// Used two ways: by unit tests to drive the manager through offline→online
/// transitions deterministically, and by a launch flag to demo the offline
/// banner + auto-resume-on-reconnect in the Simulator (where you can't script
/// real Wi-Fi). `@unchecked Sendable`: state guarded by `lock`.
final class ScriptedConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: NetworkStatus
    private var subscribers: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]

    init(initial: NetworkStatus) {
        self.latest = initial
    }

    func currentStatus() -> NetworkStatus {
        lock.withLock { latest }
    }

    func statusUpdates() -> AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            let id = UUID()
            let current: NetworkStatus = lock.withLock {
                subscribers[id] = continuation
                return latest
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    /// Push a new status to all subscribers.
    func set(_ status: NetworkStatus) {
        let conts: [AsyncStream<NetworkStatus>.Continuation] = lock.withLock {
            latest = status
            return Array(subscribers.values)
        }
        conts.forEach { $0.yield(status) }
    }

    func cancel() {
        let conts = lock.withLock { () -> [AsyncStream<NetworkStatus>.Continuation] in
            let values = Array(subscribers.values)
            subscribers.removeAll()
            return values
        }
        conts.forEach { $0.finish() }
    }
}
