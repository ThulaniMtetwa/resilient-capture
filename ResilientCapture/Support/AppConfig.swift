import Foundation

/// Static app configuration, with launch-flag overrides so the secure transport
/// (HTTPS + pinning + auth) can be exercised against the local mock without a
/// production backend. Overrides are read from `UserDefaults` (the `-key value`
/// launch-argument convention).
enum AppConfig {
    /// The upload endpoint. Defaults to the plain-http localhost mock; override
    /// with `-uploadEndpoint https://127.0.0.1:8443/upload` for the secure demo.
    static var uploadEndpoint: URL {
        if let override = UserDefaults.standard.string(forKey: "uploadEndpoint"),
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://127.0.0.1:8080/upload")!
    }

    /// Pinned certificate fingerprints (base64 SHA-256 of DER). Empty = no
    /// pinning. Override with `-pinnedKeys <hash1,hash2>`.
    static var pinnedCertificates: [String] {
        (UserDefaults.standard.string(forKey: "pinnedKeys") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The bearer token for uploads. Production reads this from the Keychain via
    /// `AuthTokenStore`; a launch override (`-authToken <t>`) supports the demo
    /// and unsigned builds where the Keychain is unavailable.
    static var bearerToken: String? {
        if let override = UserDefaults.standard.string(forKey: "authToken"), !override.isEmpty {
            return override
        }
        return AuthTokenStore.currentToken()
    }
}
