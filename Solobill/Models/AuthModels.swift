import Foundation

// Sign-in and account types from plan 23. They follow `web/src/shared/auth.ts` and
// `web/src/shared/api-responses.ts`.

enum AuthProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case google
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .apple: "Apple"
        }
    }
}

enum WorkspaceRole: String, Decodable, Sendable {
    case owner, admin, member
}

struct Workspace: Decodable, Sendable, Equatable {
    let id: Int
    let name: String
}

/// `GET /auth/providers`. Public, so the login screen can hide what the server has not set up.
struct AuthProviders: Decodable, Sendable, Equatable {
    let registration: Bool
    let google: Bool
    let apple: Bool
    let googleIosClientId: String?
    let googleAndroidClientId: String?

    /// What an older server, with no such route, offers.
    static let none = AuthProviders(
        registration: false,
        google: false,
        apple: false,
        googleIosClientId: nil,
        googleAndroidClientId: nil
    )

    /// Google needs the iOS client id as well as the switch.
    var googleClientID: String? {
        guard google, let id = googleIosClientId, !id.isEmpty else { return nil }
        return id
    }

    func offers(_ provider: AuthProvider) -> Bool {
        switch provider {
        case .google: googleClientID != nil
        case .apple: apple
        }
    }
}

/// A linked Google or Apple sign-in, from `GET /auth/identities`.
struct Identity: Decodable, Sendable, Equatable, Identifiable {
    let provider: AuthProvider
    let email: String?
    let createdAt: String

    var id: AuthProvider { provider }
}

/// What a native Google or Apple sign-in hands back, ready for the server.
struct ProviderCredential: Sendable, Equatable {
    let provider: AuthProvider
    let idToken: String
    /// The raw nonce. The ID token carries its SHA-256 (Apple) or the raw value (Google).
    let nonce: String
    /// Apple only.
    let authorizationCode: String?
    /// Apple only, and only on the first sign-in.
    let name: String?
}

// MARK: - Request bodies

struct RegisterInput: Encodable, Sendable {
    let email: String
    let password: String
    let name: String?
    let workspaceName: String
}

struct EmailInput: Encodable, Sendable {
    let email: String
}

struct OAuthTokenInput: Encodable, Sendable {
    let idToken: String
    let nonce: String
    let authorizationCode: String?
    let name: String?
    let deviceName: String

    init(_ credential: ProviderCredential, deviceName: String) {
        idToken = credential.idToken
        nonce = credential.nonce
        authorizationCode = credential.authorizationCode
        name = credential.name
        self.deviceName = deviceName
    }
}

struct OAuthLinkInput: Encodable, Sendable {
    let idToken: String
    let nonce: String
    let authorizationCode: String?
    let name: String?

    init(_ credential: ProviderCredential) {
        idToken = credential.idToken
        nonce = credential.nonce
        authorizationCode = credential.authorizationCode
        name = credential.name
    }
}

struct ChangePasswordInput: Encodable, Sendable {
    /// Required when the user already has a password.
    let currentPassword: String?
    let newPassword: String
}

/// Used for both `POST /auth/totp/disable` and `DELETE /auth/account`: the password, or a current
/// two-step code.
struct ConfirmInput: Encodable, Sendable {
    let password: String?
    let code: String?
}

struct WorkspaceInput: Encodable, Sendable {
    let name: String
}

struct TotpState: Decodable, Sendable {
    let totpEnabled: Bool
}

/// Passwords are 10 to 200 characters, the same rule as the server.
enum PasswordRule {
    static let minimum = 10
    static let maximum = 200

    /// Nil when the password is fine, otherwise what to fix.
    static func problem(_ password: String) -> String? {
        if password.count < minimum { return "Use at least \(minimum) characters." }
        if password.count > maximum { return "Use at most \(maximum) characters." }
        return nil
    }
}

// MARK: - Error codes

/// The `error` strings the server uses as codes, listed in `web/src/shared/auth.ts`. Every other
/// `error` is a message to show as it is.
enum AuthErrorCode: String, Sendable, CaseIterable {
    /// 401: ask for the 6-digit code and send again with it.
    case totpRequired = "totp_required"
    /// 403: show "Check your email" with a Resend button.
    case emailUnverified = "email_unverified"
    /// 403: sign-up is closed.
    case registrationClosed = "registration_closed"
    /// 403: sign in with Google or Apple again, then retry.
    case recentSignInRequired = "recent_sign_in_required"

    var status: Int {
        switch self {
        case .totpRequired: 401
        case .emailUnverified, .registrationClosed, .recentSignInRequired: 403
        }
    }

    var message: String {
        switch self {
        case .totpRequired: "Enter the 6-digit code from your authenticator app."
        case .emailUnverified: "Check your email for the link to confirm your address, then log in."
        case .registrationClosed: "Sign-up is closed right now."
        case .recentSignInRequired: "For your security, sign in again to continue."
        }
    }
}

extension Error {
    /// The server's code, if this is one of the known ones with its expected status.
    var authCode: AuthErrorCode? {
        guard case .server(let status, let text) = self as? APIError,
            let code = AuthErrorCode(rawValue: text),
            code.status == status
        else { return nil }
        return code
    }
}
