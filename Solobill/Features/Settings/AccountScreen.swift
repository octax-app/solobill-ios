import SwiftUI

struct AccountData: Sendable {
    let me: Me
    let identities: [Identity]
    let providers: AuthProviders

    func identity(_ provider: AuthProvider) -> Identity? {
        identities.first { $0.provider == provider }
    }

    /// Linked providers this device can sign in with again, to confirm before deleting.
    var confirmableProviders: [AuthProvider] {
        identities.map(\.provider).filter(providers.offers)
    }
}

/// Settings → Account: profile, sign-in methods, password, two-step login and deletion.
struct AccountScreen: View {
    @Environment(\.api) private var api

    var body: some View {
        Loadable { [api] in
            async let me = api.me()
            async let identities = api.identities()
            async let providers = api.authProviders()
            return AccountData(
                me: try await me,
                identities: try await identities,
                providers: (try? await providers) ?? .none
            )
        } content: { data, reload in
            AccountForm(data: data, reload: reload)
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountForm: View {
    let data: AccountData
    let reload: @Sendable () async -> Void

    @Environment(\.api) private var api
    @State private var working: AuthProvider?
    @State private var unlinking: AuthProvider?
    @State private var methodsMessage: String?
    @State private var editingPassword = false
    @State private var disablingTotp = false
    @State private var deleting = false

    private var me: Me { data.me }

    /// Linked providers, and the ones the server offers that could be linked.
    private var shownProviders: [AuthProvider] {
        AuthProvider.allCases.filter { data.identity($0) != nil || data.providers.offers($0) }
    }

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Name", value: me.name ?? "Not set")
                LabeledContent("Email", value: me.email)
                    .accessibilityIdentifier("account.email")
            }

            if !shownProviders.isEmpty {
                Section {
                    ForEach(shownProviders) { provider in
                        methodRow(provider)
                    }
                    if let methodsMessage {
                        Text(methodsMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("account.methodsError")
                    }
                } header: {
                    Text("Sign-in methods")
                } footer: {
                    Text("Your last way to sign in can't be removed.")
                }
            }

            Section {
                Button(me.hasPassword ? "Change password" : "Set a password") { editingPassword = true }
                    .accessibilityIdentifier("account.password")
            } header: {
                Text("Password")
            } footer: {
                if !me.hasPassword {
                    Text("You sign in with Apple or Google. A password lets you sign in with your email too.")
                }
            }

            Section {
                LabeledContent("Two-step login", value: me.totpEnabled ? "On" : "Off")
                    .accessibilityIdentifier("account.totp")
                if me.totpEnabled {
                    Button("Turn off two-step login", role: .destructive) { disablingTotp = true }
                }
            } footer: {
                Text(
                    me.totpEnabled
                        ? "A code from your authenticator app is asked for when you log in with your password."
                        : "Turn it on from Account settings in the web app. It applies to password sign-in."
                )
            }

            Section {
                Button("Delete account", role: .destructive) { deleting = true }
                    .accessibilityIdentifier("account.delete")
            } footer: {
                Text("Deletes your account and the workspace \(me.workspace.name), with all of its data.")
            }
        }
        .confirmationDialog(
            "Unlink \(unlinking?.title ?? "")?",
            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
            titleVisibility: .visible,
            presenting: unlinking
        ) { provider in
            Button("Unlink", role: .destructive) { Task { await unlink(provider) } }
        } message: { provider in
            Text("You won't be able to sign in with \(provider.title) until you link it again.")
        }
        .sheet(isPresented: $editingPassword) {
            PasswordSheet(email: me.email, hasPassword: me.hasPassword, saved: reload)
        }
        .sheet(isPresented: $disablingTotp) {
            TotpDisableSheet(hasPassword: me.hasPassword, saved: reload)
        }
        .sheet(isPresented: $deleting) {
            DeleteAccountSheet(data: data)
        }
    }

    @ViewBuilder
    private func methodRow(_ provider: AuthProvider) -> some View {
        if let identity = data.identity(provider) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                    if let email = identity.email {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Unlink", role: .destructive) { unlinking = provider }
                    .buttonStyle(.borderless)
                    .disabled(working != nil)
                    .accessibilityIdentifier("account.unlink.\(provider.rawValue)")
            }
        } else {
            Button {
                Task { await link(provider) }
            } label: {
                HStack {
                    Text("Link \(provider.title)")
                    if working == provider {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(working != nil)
            .accessibilityIdentifier("account.link.\(provider.rawValue)")
        }
    }

    private func link(_ provider: AuthProvider) async {
        working = provider
        defer { working = nil }
        methodsMessage = nil
        do {
            let credential = try await data.providers.signIn(with: provider)
            try await api.linkIdentity(credential)
            await reload()
        } catch is CancellationError {
            return
        } catch {
            methodsMessage = error.localizedDescription
        }
    }

    private func unlink(_ provider: AuthProvider) async {
        working = provider
        defer { working = nil }
        methodsMessage = nil
        do {
            try await api.unlinkIdentity(provider)
            await reload()
        } catch {
            // 409 when it is the last way to sign in. The server's message says so.
            methodsMessage = error.localizedDescription
        }
    }
}
