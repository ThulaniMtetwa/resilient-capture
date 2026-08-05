import Foundation

/// The **connectivity seam**: observing network reachability.
///
/// A protocol (not a bare `NWPathMonitor`) so the upload manager's pause/resume
/// behaviour and the UI's status banner can be driven by a deterministic fake in
/// tests - you can't reliably toggle real Wi-Fi from a unit test.
protocol ConnectivityMonitor: Sendable {
    /// The latest known status, available synchronously (e.g. at launch, before
    /// the first async update arrives).
    func currentStatus() -> NetworkStatus

    /// A stream of status changes. Emits the current status immediately on
    /// subscription, then again whenever the path changes. Multiple subscribers
    /// are supported (the UI reads it; so does the manager, via the model).
    func statusUpdates() -> AsyncStream<NetworkStatus>

    /// Stop monitoring and finish all streams.
    func cancel()
}
