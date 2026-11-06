import Foundation

/// Plan 23: registration, Google and Apple sign-in, and the account. Calls before sign-in are
/// sent without the token.
extension APIClient {
    func authProviders() async throws -> AuthProviders {
        try await get("auth/providers", authenticated: false)
    }

    /// Always answers the same, whether or not the email is taken. The server then sends either a
    /// verification link or an "already have an account" email.
    func register(_ input: RegisterInput) async throws {
        let _: OkResponse = try await post("auth/register", body: input, authenticated: false)
    }

    func resendVerification(email: String) async throws {
        let _: OkResponse = try await post(
            "auth/resend-verification",
            body: EmailInput(email: email),
            authenticated: false
        )
    }

    func forgotPassword(email: String) async throws {
        let _: OkResponse = try await post(
            "auth/forgot-password",
            body: EmailInput(email: email),
            authenticated: false
        )
    }

    /// Signs in with a native Google or Apple credential and returns a bearer token, the same as
    /// `createToken`.
    func oauthToken(_ credential: ProviderCredential, deviceName: String) async throws -> ApiToken {
        try await post(
            "auth/oauth/\(credential.provider.rawValue)/token",
            body: OAuthTokenInput(credential, deviceName: deviceName),
            authenticated: false
        )
    }

    func identities() async throws -> [Identity] { try await get("auth/identities") }

    @discardableResult
    func linkIdentity(_ credential: ProviderCredential) async throws -> Identity {
        try await post("auth/oauth/\(credential.provider.rawValue)/link", body: OAuthLinkInput(credential))
    }

    /// Refused with 409 while it is the last way to sign in.
    func unlinkIdentity(_ provider: AuthProvider) async throws {
        try await delete("auth/identities/\(provider.rawValue)")
    }

    func changePassword(current: String?, new: String) async throws {
        let _: OkResponse = try await post(
            "auth/password",
            body: ChangePasswordInput(currentPassword: current, newPassword: new)
        )
    }

    /// The password, or, for a user without one, a current code.
    func disableTotp(password: String?, code: String?) async throws -> TotpState {
        try await post("auth/totp/disable", body: ConfirmInput(password: password, code: code))
    }

    /// Needs the password, a two-step code, or a Google or Apple sign-in in the last 10 minutes.
    /// Deletes the workspace, its files and the user.
    func deleteAccount(password: String?, code: String?) async throws {
        try await delete("auth/account", body: ConfirmInput(password: password, code: code))
    }

    func renameWorkspace(_ name: String) async throws -> Workspace {
        try await put("workspace", body: WorkspaceInput(name: name))
    }
}
