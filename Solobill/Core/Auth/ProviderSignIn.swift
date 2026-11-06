import AuthenticationServices
import Foundation
import UIKit

enum ProviderSignInError: LocalizedError, Equatable {
    /// The provider answered without an ID token.
    case noToken
    /// The Google client id from the server is not one Google issues for iOS.
    case badClientID
    /// The browser came back without a code, or with someone else's sign-in.
    case badCallback
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noToken: "The sign-in did not return the details this app needs. Try again."
        case .badClientID: "Google sign-in is not set up correctly on the server."
        case .badCallback: "The sign-in could not be completed. Try again."
        case .failed(let message): message
        }
    }
}

// MARK: - Apple

/// Sign in with Apple through `AuthenticationServices`. The login screen uses
/// `SignInWithAppleButton` with `prepare` and `credential`. The Account screen uses `run`.
enum AppleSignIn {
    /// Asks for the name and email, and sets the hashed nonce. Returns the raw nonce, which the
    /// server needs to check the token.
    static func prepare(_ request: ASAuthorizationAppleIDRequest) -> String {
        let nonce = AuthCrypto.randomNonce()
        request.requestedScopes = [.fullName, .email]
        request.nonce = AuthCrypto.sha256Hex(nonce)
        return nonce
    }

    static func credential(from authorization: ASAuthorization, nonce: String) throws -> ProviderCredential {
        guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = apple.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else { throw ProviderSignInError.noToken }
        return ProviderCredential(
            provider: .apple,
            idToken: idToken,
            nonce: nonce,
            authorizationCode: apple.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
            name: displayName(apple.fullName)
        )
    }

    /// Apple sends the name only the first time. Empty parts make an empty string, so that is nil.
    static func displayName(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let name = PersonNameComponentsFormatter().string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(120))
    }

    /// A closed sheet is a `CancellationError`, which screens ignore.
    static func mapError(_ error: Error) -> Error {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            return CancellationError()
        }
        if error is ProviderSignInError { return error }
        return ProviderSignInError.failed("Sign in with Apple did not finish. Try again.")
    }

    /// Shows the Apple sheet without the button, to link Apple or to confirm before deleting.
    @MainActor
    static func run() async throws -> ProviderCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        let nonce = prepare(request)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        var delegate: AppleDelegate?
        let credential: ProviderCredential = try await withCheckedThrowingContinuation { continuation in
            let created = AppleDelegate(nonce: nonce, continuation: continuation)
            delegate = created
            controller.delegate = created
            controller.presentationContextProvider = created
            controller.performRequests()
        }
        // The controller holds its delegate weakly.
        withExtendedLifetime(delegate) {}
        return credential
    }
}

private final class AppleDelegate: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding, @unchecked Sendable
{
    private let nonce: String
    private let continuation: CheckedContinuation<ProviderCredential, Error>

    init(nonce: String, continuation: CheckedContinuation<ProviderCredential, Error>) {
        self.nonce = nonce
        self.continuation = continuation
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        continuation.resume(with: Result { try AppleSignIn.credential(from: authorization, nonce: nonce) })
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation.resume(throwing: AppleSignIn.mapError(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { PresentationAnchor.current() }
    }
}

// MARK: - Google

/// Google sign-in for an installed app: the browser with PKCE, then the code is exchanged for an
/// ID token here. There is no client secret and no Google SDK.
struct GoogleOAuth: Sendable, Equatable {
    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let clientSuffix = ".apps.googleusercontent.com"

    let clientID: String
    let redirectScheme: String

    /// Nil for a client id that is not an iOS client id from Google.
    init?(clientID: String) {
        guard let scheme = Self.redirectScheme(clientID: clientID) else { return nil }
        self.clientID = clientID
        redirectScheme = scheme
    }

    /// `123-abc.apps.googleusercontent.com` becomes `com.googleusercontent.apps.123-abc`, the
    /// reversed client id Google accepts as an iOS redirect scheme.
    static func redirectScheme(clientID: String) -> String? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard id.hasSuffix(clientSuffix) else { return nil }
        let prefix = id.dropLast(clientSuffix.count)
        guard !prefix.isEmpty, !prefix.contains("/"), !prefix.contains(":") else { return nil }
        return "com.googleusercontent.apps.\(prefix)"
    }

    var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    /// `nonce` is the raw value. Google puts it in the ID token unchanged.
    func authorizationURL(pkce: PKCE, state: String, nonce: String) -> URL {
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    /// The code from the redirect, after checking it answers this sign-in's `state`.
    func code(from callback: URL, state: String) throws -> String {
        guard callback.scheme == redirectScheme,
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else { throw ProviderSignInError.badCallback }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if value("error") == "access_denied" { throw CancellationError() }
        if value("error") != nil { throw ProviderSignInError.failed("Google sign-in did not finish. Try again.") }
        guard value("state") == state, let code = value("code"), !code.isEmpty else {
            throw ProviderSignInError.badCallback
        }
        return code
    }

    func tokenRequest(code: String, pkce: PKCE) -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            Self.formEncoded([
                ("grant_type", "authorization_code"),
                ("code", code),
                ("client_id", clientID),
                ("redirect_uri", redirectURI),
                ("code_verifier", pkce.verifier),
            ]).utf8
        )
        return request
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escape(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// Reads the ID token from Google's token response.
    static func idToken(from data: Data, status: Int) throws -> String {
        struct TokenResponse: Decodable {
            let id_token: String?
        }
        guard (200..<300).contains(status) else {
            throw ProviderSignInError.failed("Google sign-in did not finish. Try again.")
        }
        guard let token = (try? JSONDecoder().decode(TokenResponse.self, from: data))?.id_token,
            !token.isEmpty
        else { throw ProviderSignInError.noToken }
        return token
    }

    /// Opens Google in the system browser sheet and returns the signed-in credential.
    @MainActor
    func signIn(session urlSession: URLSession = .shared) async throws -> ProviderCredential {
        let pkce = PKCE.random()
        let state = AuthCrypto.randomURLSafe(byteCount: 16)
        let nonce = AuthCrypto.randomNonce()
        let callback = try await WebAuthentication.start(
            url: authorizationURL(pkce: pkce, state: state, nonce: nonce),
            scheme: redirectScheme
        )
        let code = try code(from: callback, state: state)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: tokenRequest(code: code, pkce: pkce))
        } catch {
            throw APIError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ProviderCredential(
            provider: .google,
            idToken: try Self.idToken(from: data, status: status),
            nonce: nonce,
            authorizationCode: nil,
            name: nil
        )
    }
}

/// Runs `ASWebAuthenticationSession` and returns the callback URL. The custom scheme needs no
/// entry in Info.plist, because the session catches it itself.
private final class WebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding,
    @unchecked Sendable
{
    @MainActor
    static func start(url: URL, scheme: String) async throws -> URL {
        let provider = WebAuthentication()
        var session: ASWebAuthenticationSession?
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let created = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) {
                @Sendable url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: ProviderSignInError.failed("Google sign-in did not finish. Try again."))
                }
            }
            created.presentationContextProvider = provider
            session = created
            if !created.start() {
                continuation.resume(throwing: ProviderSignInError.failed("Google sign-in could not open. Try again."))
            }
        }
        withExtendedLifetime((provider, session)) {}
        return callback
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { PresentationAnchor.current() }
    }
}

enum PresentationAnchor {
    @MainActor
    static func current() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
        if let scene = scenes.first { return UIWindow(windowScene: scene) }
        return ASPresentationAnchor()
    }
}

// MARK: - Either provider

extension AuthProviders {
    /// Runs the native sign-in for `provider`. Used to link and to confirm before deleting.
    @MainActor
    func signIn(with provider: AuthProvider) async throws -> ProviderCredential {
        switch provider {
        case .apple:
            return try await AppleSignIn.run()
        case .google:
            guard let id = googleClientID, let google = GoogleOAuth(clientID: id) else {
                throw ProviderSignInError.badClientID
            }
            return try await google.signIn()
        }
    }
}
