import CloudCore
import Core
import Foundation
import ImmichAPI

/// Immich (https://immich.app) as the app's Cloud.
public struct ImmichProvider: CloudProvider {
    public let name = "Immich"
    private let session: URLSession

    public init(session: URLSession = ImmichClient.makeSession()) {
        self.session = session
    }

    public var prober: any ServerProber { PingProber() }

    public func serverInfo(at server: URL) async throws -> CloudServerInfo {
        do {
            let version = try await ImmichClient.make(server: server, session: session).serverVersion()
            return CloudServerInfo(version: version.description, warning: VersionCheck(server: version).warning)
        } catch {
            throw APIError.wrap(error, operation: "Version check")
        }
    }

    public func signIn(at server: URL, email: String, password: String) async throws -> CloudSignIn {
        let result = try await ImmichClient.make(server: server, session: session).login(email: email, password: password)
        return CloudSignIn(token: result.accessToken, userID: result.userID, email: result.email, name: result.name, isAdmin: result.isAdmin)
    }

    public func loginOptions(at server: URL) async throws -> CloudLoginOptions {
        let options = try await ImmichClient.make(server: server, session: session).loginOptions()
        let buttonTitle = options.oauthButtonText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = options.loginPageMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudLoginOptions(
            passwordLogin: options.passwordLogin,
            oauth: options.oauth
                ? .init(buttonTitle: buttonTitle.isEmpty ? "Login with OAuth" : buttonTitle, autoLaunch: options.oauthAutoLaunch)
                : nil,
            message: message.isEmpty ? nil : message
        )
    }

    public func startOAuth(at server: URL) async throws -> CloudOAuthRequest {
        let pkce = PKCE()
        let state = PKCE.randomToken()
        let url = try await ImmichClient.make(server: server, session: session)
            .startOAuth(redirectURI: ImmichOAuth.redirectURI, state: state, codeChallenge: pkce.challenge)
        return CloudOAuthRequest(
            server: server, authorizeURL: url, callbackScheme: ImmichOAuth.callbackScheme,
            state: state, codeVerifier: pkce.verifier
        )
    }

    public func finishOAuth(_ request: CloudOAuthRequest, callbackURL: URL) async throws -> CloudSignIn {
        let result = try await ImmichClient.make(server: request.server, session: session)
            .finishOAuth(callbackURL: callbackURL, state: request.state, codeVerifier: request.codeVerifier)
        return CloudSignIn(token: result.accessToken, userID: result.userID, email: result.email, name: result.name, isAdmin: result.isAdmin)
    }

    public func signOut(at server: URL, token: String) async {
        do {
            try await ImmichClient.make(server: server, session: session) { token }.logoutSession()
        } catch {
            Log.networking.notice("Server sign-out failed (continuing): \(APIError.wrap(error, operation: "Sign out").message, privacy: .public)")
        }
    }

    public func connection(to server: ActiveServer, token: String) -> any CloudConnection {
        ImmichConnection(server: server, token: token, session: session)
    }

    public func uploadResult(statusCode: Int, body: Data) -> Result<CloudUploadResult, CloudError> {
        // Parsing doesn't use the address or token.
        ImmichBackupTransport(server: URL(string: "http://localhost")!, token: "").uploadResult(statusCode: statusCode, body: body)
    }
}
