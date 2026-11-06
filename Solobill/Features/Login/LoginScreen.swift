import SwiftUI

struct LoginScreen: View {
    @Environment(Session.self) private var session
    @Environment(\.api) private var api

    @State private var providers = AuthProviders.none
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var unverifiedEmail: String?
    @State private var working = false
    @State private var message: String?
    #if DEBUG
    @State private var server = ServerConfig.baseURL.absoluteString
    #endif

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (!needsCode || !code.isEmpty) && !working
    }

    /// Reloads what the server offers when the Debug server URL changes.
    private var serverKey: String {
        #if DEBUG
        server
        #else
        ""
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                if providers.apple || providers.googleClientID != nil {
                    Section {
                        ProviderButtons(providers: providers, disabled: working) { run in
                            Task { await signIn(with: run) }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("login.email")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("login.password")
                    if needsCode {
                        TextField("6-digit code", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("login.code")
                    }
                }
                if let unverifiedEmail {
                    Section {
                        CheckEmailView(email: unverifiedEmail)
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("login.error")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text("Log in")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("login.submit")
                    NavigationLink("Forgot password?") {
                        ForgotPasswordScreen(email: email.trimmingCharacters(in: .whitespaces))
                    }
                    .accessibilityIdentifier("login.forgot")
                }
                if providers.registration {
                    Section {
                        NavigationLink("Create account") { RegisterScreen() }
                            .accessibilityIdentifier("login.register")
                    } footer: {
                        Text("Sign up with your email, or with Apple or Google above.")
                    }
                }
                #if DEBUG
                Section("Debug server") {
                    TextField("Server URL", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: server) { _, value in ServerConfig.setOverride(value) }
                }
                #endif
            }
            .navigationTitle("Octax Solobill")
            .task(id: serverKey) { await loadProviders() }
        }
    }

    /// A server without these routes, or one that can't be reached, offers email sign-in only.
    private func loadProviders() async {
        #if DEBUG
        // Waits for typing in the server field to settle.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        #endif
        do {
            providers = try await api.authProviders()
        } catch is CancellationError {
            return
        } catch {
            providers = .none
        }
    }

    private func submit() async {
        working = true
        defer { working = false }
        message = nil
        unverifiedEmail = nil
        do {
            try await session.signIn(email: email, password: password, code: needsCode ? code : nil)
        } catch LoginError.codeRequired {
            needsCode = true
        } catch LoginError.emailUnverified {
            unverifiedEmail = email.trimmingCharacters(in: .whitespaces)
        } catch {
            message = error.localizedDescription
        }
    }

    private func signIn(with run: @MainActor () async throws -> ProviderCredential) async {
        working = true
        defer { working = false }
        message = nil
        unverifiedEmail = nil
        do {
            let credential = try await run()
            try await session.signIn(with: credential)
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }
}
