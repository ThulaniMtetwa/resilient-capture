import Foundation

/// Static app configuration. Kept tiny and in one place so the walkthrough has a
/// single answer to "where does the endpoint come from".
enum AppConfig {
    /// The mock verification endpoint. The iOS Simulator shares the Mac's
    /// network, so `127.0.0.1` reaches the Python mock server directly.
    ///
    /// Note: we use the IPv4 literal `127.0.0.1` rather than `localhost`. A
    /// background `URLSession`'s transfer daemon on the Simulator resolves
    /// `localhost` to IPv6 `::1` first and fails there; pinning IPv4 avoids it.
    static let uploadEndpoint = URL(string: "http://127.0.0.1:8080/upload")!
}
