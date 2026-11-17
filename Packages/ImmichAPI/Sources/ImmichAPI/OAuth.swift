import Foundation
import OpenAPIRuntime

/// How the server lets people sign in, as its own login page shows it.
public struct LoginOptions: Sendable, Equatable {
    public let passwordLogin: Bool
    public let oauth: Bool
    /// The server opens the OAuth sign-in straight away instead of showing its login page.
    public let oauthAutoLaunch: Bool
    /// Empty when the server has none.
    public let oauthButtonText: String
    /// Shown on the server's login page; empty when there is none.
    public let loginPageMessage: String
}

extension Client {
    /// `GET /server/features` and `GET /server/config`: both work before signing in.
    public func loginOptions() async throws -> LoginOptions {
        do {
            async let featuresOutput = getServerFeatures()
            async let configOutput = getServerConfig()
            let features: Components.Schemas.ServerFeaturesDto
            switch try await featuresOutput {
            case .ok(let response): features = try response.body.json
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "read the server's sign-in options")
            }
            let config: Components.Schemas.ServerConfigDto
            switch try await configOutput {
            case .ok(let response): config = try response.body.json
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "read the server's sign-in options")
            }
            return LoginOptions(
                passwordLogin: features.passwordLogin,
                oauth: features.oauth,
                oauthAutoLaunch: features.oauthAutoLaunch,
                oauthButtonText: config.oauthButtonText,
                loginPageMessage: config.loginPageMessage
            )
        } catch {
            throw APIError.wrap(error, operation: "Sign-in options")
        }
    }

    /// `POST /oauth/authorize`: the identity provider's page to open in a browser.
    public func startOAuth(redirectURI: String, state: String, codeChallenge: String) async throws -> URL {
        do {
            let body = Components.Schemas.OAuthConfigDto(codeChallenge: codeChallenge, redirectUri: redirectURI, state: state)
            switch try await startOAuth(body: .json(body)) {
            case .created(let response):
                let text = try response.body.json.url
                guard let url = URL(string: text) else {
                    throw APIError(kind: .decoding, message: "The server returned an invalid sign-in address.")
                }
                return url
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "start the sign-in")
            }
        } catch {
            throw APIError.wrap(error, operation: "Start sign-in")
        }
    }

    /// `POST /oauth/callback`: trades the provider's redirect (with its code) for a session.
    public func finishOAuth(callbackURL: URL, state: String, codeVerifier: String) async throws -> LoginResult {
        do {
            let body = Components.Schemas.OAuthCallbackDto(codeVerifier: codeVerifier, state: state, url: callbackURL.absoluteString)
            switch try await finishOAuth(body: .json(body)) {
            case .created(let response):
                let dto = try response.body.json
                return LoginResult(
                    accessToken: dto.accessToken,
                    userID: dto.userId,
                    email: dto.userEmail,
                    name: dto.name,
                    isAdmin: dto.isAdmin
                )
            case .undocumented(let status, let payload):
                throw await APIError.from(statusCode: status, payload: payload, operation: "finish the sign-in")
            }
        } catch {
            throw APIError.wrap(error, operation: "Finish sign-in")
        }
    }
}
