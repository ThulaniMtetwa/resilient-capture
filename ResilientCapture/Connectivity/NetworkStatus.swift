import Foundation

/// A plain snapshot of network reachability, decoupled from `Network.framework`
/// types so the manager, model, and tests can pass it around freely.
struct NetworkStatus: Sendable, Equatable {
    /// The active interface, for user-facing hints ("over Cellular").
    enum Interface: String, Sendable, Equatable {
        case wifi = "Wi-Fi"
        case cellular = "Cellular"
        case wired = "Wired"
        case other = "Network"
        case none = "No network"
    }

    /// Whether a usable path exists (`NWPath.status == .satisfied`).
    var isOnline: Bool
    /// Metered / personal-hotspot / cellular - worth telling the user about.
    var isExpensive: Bool
    /// Low Data Mode.
    var isConstrained: Bool
    var interface: Interface

    /// Optimistic default before the monitor reports its first path.
    static let unknownOnline = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: false, interface: .other)
    static let offline = NetworkStatus(isOnline: false, isExpensive: false, isConstrained: false, interface: .none)
}
