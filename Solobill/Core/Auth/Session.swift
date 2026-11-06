import Foundation
import LocalAuthentication
import Observation
import UIKit

/// Asks the owner to prove who they are. Returns whether they passed.
typealias Authenticator = @MainActor @Sendable () async -> Bool

/// Face ID, falling back to the device passcode. A device with no passcode set has nothing to
/// check against, so it opens without a prompt.
let deviceAuthenticator: Authenticator = {
    #if DEBUG
    // UI tests cannot get past the system sheet. This is not in Release builds.
    if UserDefaults.standard.bool(forKey: "skipAppLock") { return true }
    #endif
    let context = LAContext()
    var unavailable: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
        return true
    }
    return (try? await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: "Unlock your customer and invoice data"
    )) ?? false
}

enum LoginError: LocalizedError, Equatable {
    /// The password was right, and the account needs a two-step code.
    case codeRequired
    /// The password was right, and the email address has not been confirmed yet.
    case emailUnverified
    /// A fresh sign-in, to confirm before deleting, signed in to a different account.
    case differentAccount

    var errorDescription: String? {
        switch self {
        case .codeRequired: AuthErrorCode.totpRequired.message
        case .emailUnverified: AuthErrorCode.emailUnverified.message
        case .differentAccount: "That sign-in belongs to a different account. Use the one linked to this account."
        }
    }

    /// The login error for a server error, if it is one the login screen handles itself.
    init?(_ error: Error) {
        switch error.authCode {
        case .totpRequired: self = .codeRequired
        case .emailUnverified: self = .emailUnverified
        default: return nil
        }
    }
}

/// Whether the owner is logged in and whether the app is unlocked.
@MainActor
@Observable
final class Session {
    enum State {
        case signedOut
        case locked
        case active
    }

    private(set) var state: State

    @ObservationIgnored let api: APIClient
    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored private let authenticate: Authenticator
    @ObservationIgnored private var authenticating = false
    @ObservationIgnored private var promptedSinceLock = false

    init(
        api: APIClient,
        tokens: any TokenStore = KeychainTokenStore(),
        authenticate: @escaping Authenticator = deviceAuthenticator
    ) {
        self.api = api
        self.tokens = tokens
        self.authenticate = authenticate
        state = tokens.load() == nil ? .signedOut : .locked
        api.onUnauthorized { [weak self] in
            Task { @MainActor in self?.endSession() }
        }
    }

    private var deviceName: String { "iOS: \(UIDevice.current.name)" }

    func signIn(email: String, password: String, code: String?) async throws {
        do {
            let created = try await api.createToken(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password,
                code: code,
                name: deviceName
            )
            try tokens.save(StoredToken(id: created.id, token: created.token))
            state = .active
        } catch {
            throw LoginError(error) ?? error
        }
    }

    /// Signs in with a native Google or Apple credential. A new person gets an account and a
    /// workspace of their own.
    func signIn(with credential: ProviderCredential) async throws {
        let created = try await api.oauthToken(credential, deviceName: deviceName)
        try tokens.save(StoredToken(id: created.id, token: created.token))
        state = .active
    }

    /// A fresh Google or Apple sign-in while signed in, which the server asks for before deleting
    /// an account without a password. It issues a new token, which replaces the stored one.
    ///
    /// The provider could sign in to a different account, so the new token is kept only when it
    /// belongs to the same user and workspace. Otherwise it is revoked and the old one stays.
    func reauthenticate(with credential: ProviderCredential, as current: Me) async throws {
        let previous = tokens.load()
        let created = try await api.oauthToken(credential, deviceName: deviceName)
        let fresh = StoredToken(id: created.id, token: created.token)
        try tokens.save(fresh)
        let matches: Bool
        do {
            let me = try await api.me()
            matches = me.email == current.email && me.workspace.id == current.workspace.id
        } catch {
            matches = false
        }
        guard matches else {
            try? await api.revokeToken(id: fresh.id)
            if let previous { try? tokens.save(previous) } else { tokens.clear() }
            throw LoginError.differentAccount
        }
        if let previous, previous.id != fresh.id {
            try? await api.revokeToken(id: previous.id)
        }
    }

    /// Deletes the account and its workspace on the server, then forgets everything on this device.
    func deleteAccount(password: String?, code: String?) async throws {
        try await api.deleteAccount(password: password, code: code)
        endSession()
        // PDFs shared into the app belonged to the deleted workspace.
        if let inbox = CaptureInbox.shared {
            inbox.waiting().forEach(inbox.remove)
        }
    }

    /// Revokes the token on the server if it can be reached. The local copy goes either way.
    func signOut() async {
        if let stored = tokens.load() {
            try? await api.revokeToken(id: stored.id)
        }
        endSession()
    }

    private func endSession() {
        tokens.clear()
        state = .signedOut
    }

    /// Called when the app leaves the screen, so the next open asks for Face ID.
    func lock() {
        guard state == .active else { return }
        state = .locked
        promptedSinceLock = false
    }

    /// Prompts once per lock. Closing a system prompt makes the app active again, so without
    /// this a cancelled prompt would reappear forever.
    func unlockAutomatically() async {
        guard !promptedSinceLock else { return }
        await unlock()
    }

    /// Prompts now, for the Unlock button.
    func unlock() async {
        guard state == .locked, !authenticating else { return }
        authenticating = true
        promptedSinceLock = true
        defer { authenticating = false }
        let passed = await authenticate()
        if passed, state == .locked { state = .active }
    }
}
