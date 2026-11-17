import AuthenticationServices
import Core
import CloudCore
import SwiftUI

/// First launch, in two steps: connect to the server, then sign in the ways that server offers.
struct OnboardingView: View {
    let model: AppModel
    @State private var path: [CloudLoginOptions] = []

    var body: some View {
        NavigationStack(path: $path) {
            ServerConnectView(model: model) { options in
                path = [options]
            }
            .navigationDestination(for: CloudLoginOptions.self) { options in
                SignInView(model: model, options: options)
            }
        }
    }
}

/// Step 1: the home and away addresses. Continue only succeeds once one of them answers.
struct ServerConnectView: View {
    let model: AppModel
    var onConnected: (CloudLoginOptions) -> Void

    @State private var local = ""
    @State private var remote = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case local, remote }

    private var addresses: ServerAddresses {
        ServerAddresses(local: ServerAddresses.normalize(local), remote: ServerAddresses.normalize(remote))
    }

    private var canContinue: Bool {
        !isConnecting && (addresses.local != nil || addresses.remote != nil)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Home") {
                    TextField("192.168.1.10:2283", text: $local)
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .local)
                        .submitLabel(.next)
                        .onSubmit { focus = .remote }
                }
                LabeledContent("Away") {
                    TextField("photos.example.com", text: $remote)
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .remote)
                        .submitLabel(.continue)
                        .onSubmit(connect)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Enter at least one address. The home address is used when it answers within 1.5 seconds; otherwise the away address (for example over Tailscale).")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textContentType(.URL)

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }
            }

            Section {
                Button(action: connect) {
                    HStack {
                        Text("Continue")
                        Spacer()
                        if isConnecting { ProgressView() }
                    }
                }
                .disabled(!canContinue)
            }
        }
        .navigationTitle("Photos")
        .onAppear {
            if local.isEmpty && remote.isEmpty {
                local = model.serverSettings.addresses.local?.absoluteString ?? ""
                remote = model.serverSettings.addresses.remote?.absoluteString ?? ""
            }
        }
        .onChange(of: local) { errorMessage = nil }
        .onChange(of: remote) { errorMessage = nil }
    }

    private func connect() {
        guard canContinue else { return }
        let invalid = [("home", local, addresses.local), ("away", remote, addresses.remote)]
            .first { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty && $0.2 == nil }
        if let invalid {
            errorMessage = "The \(invalid.0) address isn't a valid server address."
            return
        }
        focus = nil
        isConnecting = true
        errorMessage = nil
        Task {
            defer { isConnecting = false }
            do {
                let options = try await model.connect(to: addresses)
                onConnected(options)
            } catch {
                errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// Step 2 (and Add Account): reads the server's sign-in options first.
struct SignInLoader: View {
    let model: AppModel
    var initialEmail = ""
    var onSignedIn: (() -> Void)?

    @State private var options: CloudLoginOptions?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let options {
                SignInView(model: model, options: options, initialEmail: initialEmail, onSignedIn: onSignedIn)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can't Reach the Server", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
                .navigationTitle("Sign In")
            } else {
                ProgressView()
                    .navigationTitle("Sign In")
            }
        }
        .task { await load() }
    }

    private func load() async {
        errorMessage = nil
        do {
            options = try await model.loginOptions()
        } catch {
            errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
        }
    }
}

/// Signs in exactly the ways the server's own login page offers: email and password,
/// single sign-on (with the server's button title), or both.
struct SignInView: View {
    let model: AppModel
    let options: CloudLoginOptions
    /// Prefilled when adding a second account or re-signing in.
    var initialEmail = ""
    var onSignedIn: (() -> Void)?

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var email = ""
    @State private var password = ""
    @State private var working: Method?
    @State private var errorMessage: String?
    @State private var didAutoLaunch = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }
    private enum Method { case password, oauth }

    var body: some View {
        Form {
            if options.passwordLogin {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } header: {
                    Text("Cloud account")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }
            }

            if options.passwordLogin {
                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign In")
                            Spacer()
                            if working == .password { ProgressView() }
                        }
                    }
                    .disabled(working != nil || email.isEmpty || password.isEmpty)
                } footer: {
                    if options.oauth == nil { messageFooter }
                }
            }

            if let oauth = options.oauth {
                Section {
                    Button(action: signInWithOAuth) {
                        HStack {
                            Text(oauth.buttonTitle)
                            Spacer()
                            if working == .oauth { ProgressView() }
                        }
                    }
                    .disabled(working != nil)
                } header: {
                    if options.passwordLogin { Text("Or") }
                } footer: {
                    messageFooter
                }
            }

            if !options.passwordLogin && options.oauth == nil {
                Section {
                    Text("This server doesn't allow signing in with a password or single sign-on. Ask its administrator to turn one on.")
                        .foregroundStyle(.secondary)
                } footer: {
                    messageFooter
                }
            }
        }
        .navigationTitle("Sign In")
        .onAppear {
            if email.isEmpty { email = initialEmail }
            if let oauth = options.oauth, oauth.autoLaunch, !didAutoLaunch {
                didAutoLaunch = true
                signInWithOAuth()
            }
        }
    }

    @ViewBuilder private var messageFooter: some View {
        if let message = options.message { Text(message) }
    }

    private func signIn() {
        guard working == nil, !email.isEmpty, !password.isEmpty else { return }
        run(.password) {
            try await model.signIn(email: email, password: password)
            password = ""
            return true
        }
    }

    private func signInWithOAuth() {
        guard working == nil else { return }
        run(.oauth) {
            let request = try await model.startOAuth()
            let callbackURL: URL
            do {
                callbackURL = try await webAuthenticationSession.authenticate(
                    using: request.authorizeURL,
                    callback: .customScheme(request.callbackScheme),
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return false
            }
            try await model.finishOAuth(request, callbackURL: callbackURL)
            return true
        }
    }

    /// `work` returns false when the person cancelled (nothing to report).
    private func run(_ method: Method, _ work: @escaping @MainActor () async throws -> Bool) {
        working = method
        errorMessage = nil
        Task {
            defer { working = nil }
            do {
                if try await work() { onSignedIn?() }
            } catch {
                errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }
}
