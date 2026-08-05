import Foundation
import Network

/// Production `ConnectivityMonitor` backed by `NWPathMonitor`.
///
/// `NWPathMonitor` delivers path updates on a background `DispatchQueue`. We map
/// each `NWPath` to our transport-agnostic `NetworkStatus` and broadcast it to
/// all subscribers. `@unchecked Sendable`: the mutable state (latest status +
/// subscriber continuations) is guarded by `lock`.
final class PathConnectivityMonitor: ConnectivityMonitor, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.iidentifii.resilientcapture.connectivity")
    private let lock = NSLock()
    private var latest: NetworkStatus
    private var subscribers: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]

    init() {
        latest = NetworkStatus(path: monitor.currentPath)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status = NetworkStatus(path: path)
            self.broadcast(status)
        }
        monitor.start(queue: queue)
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
            continuation.yield(current)   // deliver current state immediately
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func cancel() {
        monitor.cancel()
        let conts = lock.withLock { () -> [AsyncStream<NetworkStatus>.Continuation] in
            let values = Array(subscribers.values)
            subscribers.removeAll()
            return values
        }
        conts.forEach { $0.finish() }
    }

    private func broadcast(_ status: NetworkStatus) {
        let conts: [AsyncStream<NetworkStatus>.Continuation] = lock.withLock {
            latest = status
            return Array(subscribers.values)
        }
        conts.forEach { $0.yield(status) }
    }
}

private extension NetworkStatus {
    /// Map an `NWPath` to a transport-agnostic status.
    init(path: NWPath) {
        let online = path.status == .satisfied
        let interface: Interface
        if !online {
            interface = .none
        } else if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wired
        } else {
            interface = .other
        }
        self.init(
            isOnline: online,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interface: interface
        )
    }
}
