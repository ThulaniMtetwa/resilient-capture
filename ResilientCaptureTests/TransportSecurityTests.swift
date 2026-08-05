import XCTest
import Security
@testable import ResilientCapture

/// Tests for the transport hardening: request auth headers and certificate pinning.
final class TransportSecurityTests: XCTestCase {

    // MARK: - Bearer token / request building

    func testRequestCarriesCaptureIdAndMethod() {
        let id = UUID()
        let request = BackgroundUploadTransport.makeUploadRequest(
            endpoint: URL(string: "https://verify.example/upload")!,
            captureID: id,
            bearerToken: nil
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Capture-Id"), id.uuidString)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "No token means no Authorization header")
    }

    func testRequestAddsBearerTokenWhenPresent() {
        let request = BackgroundUploadTransport.makeUploadRequest(
            endpoint: URL(string: "https://verify.example/upload")!,
            captureID: UUID(),
            bearerToken: "secret-token"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    // MARK: - Certificate pinning

    func testPinnerIsInertWhenEmpty() {
        XCTAssertFalse(CertificatePinner(pinnedSHA256: []).isActive)
        XCTAssertTrue(CertificatePinner(pinnedSHA256: ["abc"]).isActive)
    }

    /// The fingerprint computed in-app must match the one produced by
    /// `openssl x509 -outform der | openssl dgst -sha256 -binary | base64`.
    func testCertificateFingerprintMatchesOpenSSL() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.testCertDERBase64))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(
            CertificatePinner.sha256Base64(of: certificate),
            "l8Qor5ZX64tUaHZywJxzHwrHqWHD3vZ/1T8PJJ9iOPM=",
            "The pin must match the openssl-computed fingerprint of the test certificate"
        )
    }

    // A fixed self-signed test certificate (CN=127.0.0.1), DER base64. Embedded so
    // the test is self-contained and independent of any generated cert files.
    private static let testCertDERBase64 = "MIIDGjCCAgKgAwIBAgIUGPz8xxTMytRlxtvVwmN/wwACmZswDQYJKoZIhvcNAQELBQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDgwNTA3MzMxMVoXDTM2MDgwMjA3MzMxMVowFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqNrq2ISGFr4mFBdBEesRL8YvPn+HTDNXbCvdMWhzYg5278pjk8zAK3UDcEmjFyOPEl/n6RGXCZcCuiTKRVRmdHQ6mEld9s77gssqd/6tSZRpHudptFn8zfePTV44CiZVOj7dYJoIcjReK/bjgBTuGoOsvKDeAWBdOaK6amvh7IV2vnUQO4JdiN0QTolNlvpTufB0QhX/Tdp5a1vlOP1eFpGm7j3RvrBtOcVnMUkU9Ky7M+BoctCGPGzLD3gb7i7eUaJ49CjHv3QZRd9Kf6lnPaGKWqrK3CZCvgtFrPpyp+THHs+90y0W3H3eRgRt/SYPGOw6h/qXeUtfNncZ3OZkUQIDAQABo2QwYjAdBgNVHQ4EFgQU6f4avPK0QR1UJx9YeSgcNmEAgx8wHwYDVR0jBBgwFoAU6f4avPK0QR1UJx9YeSgcNmEAgx8wDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMA0GCSqGSIb3DQEBCwUAA4IBAQAxZb0pyrnUZLk76EzpATdRx8BvJuk2w4Qcd1vjTxQ59ARxDdb/hP6Zgr4Kjt/kOSQilY+hwiXV6i4I7XJxkV2BdXD3Y1gZShx8eYkQT52AaldFh28qhq+iwll4qpFN70XexbvxoMqXOr7jLq+jFOdduyisyORLZ72qbq5+FjmWbU5FO1Nb9dLqbeJyTtf9x8xg1YDBCiKh31SiEkt7e7PONE1cJ4Y3ogzqaopM5MbqH5jqgW8cHeE4asGZHxRFOH2Evg6Qk8Qm255lKAITOmWrcl1VIyBkrR1vMSXnd5kPOFvBddNvU1NLhZfX4/3QV8Lk/MHM3v9sXlNgwjKs9VY6"
}
