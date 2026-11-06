import SwiftUI

/// Deletes the account, as App Store guideline 5.1.1(v) requires. Confirms with the password, a
/// two-step code, or, for a Google or Apple only account, a fresh sign-in with that provider.
struct DeleteAccountSheet: View {
    let data: AccountData

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var code = ""
    @State private var needsFreshSignIn: Bool
    @State private var signedInAgain = false
    @State private var confirming = false
    @State private var working = false
    @State private var message: String?

    init(data: AccountData) {
        self.data = data
        _needsFreshSignIn = State(initialValue: !data.me.hasPassword && !data.me.totpEnabled)
    }

    private var me: Me { data.me }
    private var usesPassword: Bool { me.hasPassword && !needsFreshSignIn }
    private var usesCode: Bool { !me.hasPassword && me.totpEnabled && !needsFreshSignIn }

    private var canDelete: Bool {
        if working { return false }
        if needsFreshSignIn { return signedInAgain }
        if usesPassword { return !password.isEmpty }
        if usesCode { return code.trimmingCharacters(in: .whitespaces).count >= 6 }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "This permanently deletes your account and the workspace \(me.workspace.name), with every customer, invoice and stored file. It can't be undone."
                    )
                }
                if usesPassword {
                    Section {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("delete.password")
                    } footer: {
                        Text("Enter your password to confirm.")
                    }
                } else if usesCode {
                    Section {
                        TextField("6-digit code", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("delete.code")
                    } footer: {
                        Text("Enter a code from your authenticator app to confirm.")
                    }
                }
                if needsFreshSignIn {
                    freshSignInSection
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("delete.error")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirming = true
                    } label: {
                        HStack {
                            Text("Delete account")
                            if working {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canDelete)
                    .accessibilityIdentifier("delete.submit")
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete account and workspace", role: .destructive) {
                    Task { await delete() }
                }
            } message: {
                Text("Everything in \(me.workspace.name) is deleted. This can't be undone.")
            }
        }
        .interactiveDismissDisabled(working)
    }

    @ViewBuilder
    private var freshSignInSection: some View {
        Section {
            if signedInAgain {
                Label("Signed in again", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if data.confirmableProviders.isEmpty {
                Text("Sign in again from the web app to delete this account.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(data.confirmableProviders) { provider in
                    Button("Sign in with \(provider.title)") {
                        Task { await signInAgain(with: provider) }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("delete.reauth.\(provider.rawValue)")
                }
            }
        } footer: {
            Text("To confirm it's you, sign in again with the account linked here.")
        }
    }

    private func signInAgain(with provider: AuthProvider) async {
        working = true
        defer { working = false }
        message = nil
        do {
            let credential = try await data.providers.signIn(with: provider)
            try await session.reauthenticate(with: credential, as: me)
            signedInAgain = true
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    private func delete() async {
        working = true
        defer { working = false }
        message = nil
        do {
            try await session.deleteAccount(
                password: usesPassword ? password : nil,
                code: usesCode ? code.trimmingCharacters(in: .whitespaces) : nil
            )
            // The session is now signed out, and the app returns to the login screen.
        } catch where error.authCode == .recentSignInRequired {
            needsFreshSignIn = true
            signedInAgain = false
            message = data.confirmableProviders.isEmpty
                ? error.localizedDescription
                : "For your security, sign in again with \(data.confirmableProviders.map(\.title).joined(separator: " or ")), then delete."
        } catch {
            message = error.localizedDescription
        }
    }
}
