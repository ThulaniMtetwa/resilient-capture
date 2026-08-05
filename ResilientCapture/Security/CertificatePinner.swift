import Foundation
import CryptoKit

/// TLS certificate pinning.
///
/// Holds a set of pinned certificate fingerprints (base64 of the SHA-256 of the
/// certificate's DER encoding) and validates a server trust against them, so a
/// man-in-the-middle presenting a different (even validly-issued) certificate is
/// rejected. Pinning is inert when the set is empty, so the default localhost
/// mock keeps working over plain http.
///
/// Certificate pinning (whole-cert hash) is used here for a self-contained,
/// verifiable implementation. Production would typically pin the public key
/// (SPKI) instead, which survives certificate renewal when the key is reused; the
/// evaluation flow is identical.
struct CertificatePinner: Sendable {
    let pinnedSHA256: Set<String>

    var isActive: Bool { !pinnedSHA256.isEmpty }

    init(pinnedSHA256: [String]) {
        self.pinnedSHA256 = Set(pinnedSHA256.filter { !$0.isEmpty })
    }

    /// True if any certificate in the server's chain matches a pin.
    func validate(serverTrust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return false
        }
        return chain.contains { pinnedSHA256.contains(Self.sha256Base64(of: $0)) }
    }

    /// The pin for a certificate: base64(SHA-256(DER)).
    static func sha256Base64(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return Data(SHA256.hash(data: der)).base64EncodedString()
    }
}
