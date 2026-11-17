import CryptoKit
import Foundation

/// The redirect Immich's own mobile app uses. Servers that set "Mobile Redirect URI Override"
/// swap it for their `/api/oauth/mobile-redirect` page, which sends the browser back here, so
/// an identity provider set up for the official app works for this one too.
enum ImmichOAuth {
    static let callbackScheme = "app.immich"
    static let redirectURI = "app.immich:///oauth-callback"
}

/// Proof Key for Code Exchange (RFC 7636), S256.
struct PKCE: Sendable, Equatable {
    let verifier: String
    let challenge: String

    init(verifier: String = PKCE.randomToken()) {
        self.verifier = verifier
        challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes, base64url: 43 characters from the unreserved set.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
