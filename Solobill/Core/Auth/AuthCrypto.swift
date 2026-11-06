import CryptoKit
import Foundation
import Security

/// Random values and hashes for Google and Apple sign-in. Nothing here is a secret that outlives
/// one sign-in.
enum AuthCrypto {
    /// URL-safe random text from `byteCount` random bytes, with no padding.
    static func randomURLSafe(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "No secure random bytes")
        return base64URL(Data(bytes))
    }

    /// The raw nonce the app keeps. The server compares it with the one in the ID token.
    static func randomNonce() -> String { randomURLSafe(byteCount: 32) }

    /// Lowercase hex SHA-256, as Apple expects in `request.nonce`.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// RFC 7636 proof key, with the S256 method.
struct PKCE: Sendable, Equatable {
    let verifier: String

    /// 32 random bytes make a 43-character verifier, the shortest the RFC allows.
    static func random() -> PKCE { PKCE(verifier: AuthCrypto.randomURLSafe(byteCount: 32)) }

    var challenge: String { AuthCrypto.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    var method: String { "S256" }
}
