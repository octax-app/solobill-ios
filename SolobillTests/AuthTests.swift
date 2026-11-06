import Foundation
import Synchronization
import Testing

@testable import Solobill

// Plan 23: the sign-in helpers, the new responses, error codes and request bodies. The JSON here
// follows `web/src/shared/auth.ts` and `api-responses.ts` until the fixtures are regenerated.

@Suite struct AuthCryptoTests {
    @Test func sha256HexMatchesTheKnownDigest() {
        #expect(
            AuthCrypto.sha256Hex("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test func noncesAreRandomAndURLSafe() {
        let a = AuthCrypto.randomNonce()
        let b = AuthCrypto.randomNonce()
        #expect(a != b)
        #expect(a.count == 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.unicodeScalars.allSatisfy(allowed.contains))
        // The server accepts 16 to 200 characters.
        #expect((16...200).contains(a.count))
    }

    /// RFC 7636, appendix B.
    @Test func pkceMatchesTheRFCExample() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test func randomVerifiersMeetTheRFCLength() {
        let verifier = PKCE.random().verifier
        #expect((43...128).contains(verifier.count))
        #expect(PKCE.random() != PKCE.random())
    }
}

@Suite struct GoogleOAuthTests {
    private let clientID = "1234567890-abcdef.apps.googleusercontent.com"

    @Test func redirectSchemeIsTheReversedClientID() throws {
        #expect(GoogleOAuth.redirectScheme(clientID: clientID) == "com.googleusercontent.apps.1234567890-abcdef")
        let google = try #require(GoogleOAuth(clientID: clientID))
        #expect(google.redirectURI == "com.googleusercontent.apps.1234567890-abcdef:/oauth2redirect")
    }

    @Test func refusesClientIDsThatAreNotGoogleIOSIDs() {
        #expect(GoogleOAuth.redirectScheme(clientID: "") == nil)
        #expect(GoogleOAuth.redirectScheme(clientID: ".apps.googleusercontent.com") == nil)
        #expect(GoogleOAuth.redirectScheme(clientID: "web-client-id") == nil)
        #expect(GoogleOAuth(clientID: "abc.example.com") == nil)
    }

    @Test func authorizationURLAsksForAnIDTokenWithPKCEAndNonce() throws {
        let google = try #require(GoogleOAuth(clientID: clientID))
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = google.authorizationURL(pkce: pkce, state: "state-1", nonce: "raw-nonce-123456")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "accounts.google.com")
        #expect(components.path == "/o/oauth2/v2/auth")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == clientID)
        #expect(items["redirect_uri"] == google.redirectURI)
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "openid email profile")
        #expect(items["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "state-1")
        // Google gets the raw nonce and puts it in the token unchanged.
        #expect(items["nonce"] == "raw-nonce-123456")
    }

    @Test func readsTheCodeOnlyForThisSignInsState() throws {
        let google = try #require(GoogleOAuth(clientID: clientID))
        let good = try #require(URL(string: "\(google.redirectURI)?state=s1&code=4%2F0Abc"))
        #expect(try google.code(from: good, state: "s1") == "4/0Abc")

        #expect(throws: ProviderSignInError.badCallback) {
            try google.code(from: good, state: "other")
        }
        let otherScheme = try #require(URL(string: "solobill:/oauth2redirect?state=s1&code=x"))
        #expect(throws: ProviderSignInError.badCallback) {
            try google.code(from: otherScheme, state: "s1")
        }
        let denied = try #require(URL(string: "\(google.redirectURI)?state=s1&error=access_denied"))
        #expect(throws: CancellationError.self) {
            try google.code(from: denied, state: "s1")
        }
    }

    @Test func tokenRequestIsAFormPostWithTheVerifierAndNoSecret() throws {
        let google = try #require(GoogleOAuth(clientID: clientID))
        let pkce = PKCE(verifier: "verifier-value")
        let request = google.tokenRequest(code: "4/0A+b c", pkce: pkce)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        let fields = Dictionary(
            uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return (parts[0], parts[1].removingPercentEncoding ?? "")
            }
        )
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "4/0A+b c")
        #expect(fields["client_id"] == clientID)
        #expect(fields["redirect_uri"] == google.redirectURI)
        #expect(fields["code_verifier"] == "verifier-value")
        #expect(fields["client_secret"] == nil)
        // A literal "+" would read as a space.
        #expect(body.contains("code=4%2F0A%2Bb%20c"))
    }

    @Test func readsTheIDTokenFromGooglesResponse() throws {
        let data = Data(#"{"access_token":"a","id_token":"eyJ.header.sig","expires_in":3599}"#.utf8)
        #expect(try GoogleOAuth.idToken(from: data, status: 200) == "eyJ.header.sig")
        #expect(throws: ProviderSignInError.noToken) {
            try GoogleOAuth.idToken(from: Data(#"{"access_token":"a"}"#.utf8), status: 200)
        }
        #expect(throws: ProviderSignInError.self) {
            try GoogleOAuth.idToken(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)
        }
    }

    @Test func appleNamesAreJoinedOrLeftOut() {
        var components = PersonNameComponents()
        #expect(AppleSignIn.displayName(nil) == nil)
        #expect(AppleSignIn.displayName(components) == nil)
        components.givenName = "Sara"
        components.familyName = "Haddad"
        #expect(AppleSignIn.displayName(components)?.contains("Sara") == true)
        #expect(AppleSignIn.displayName(components)?.contains("Haddad") == true)
    }
}

@Suite struct AuthDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesProviders() throws {
        let providers = try decode(
            AuthProviders.self,
            #"{"registration":true,"google":true,"apple":false,"googleIosClientId":"1-a.apps.googleusercontent.com","googleAndroidClientId":null}"#
        )
        #expect(providers.registration)
        #expect(providers.googleClientID == "1-a.apps.googleusercontent.com")
        #expect(providers.offers(.google))
        #expect(!providers.offers(.apple))

        // Google switched on without an iOS client id can't be used here.
        let noClient = try decode(
            AuthProviders.self,
            #"{"registration":false,"google":true,"apple":true,"googleIosClientId":null,"googleAndroidClientId":null}"#
        )
        #expect(noClient.googleClientID == nil)
        #expect(!noClient.offers(.google))
        #expect(noClient.offers(.apple))
    }

    @Test func decodesIdentities() throws {
        let identities = try decode(
            [Identity].self,
            #"[{"provider":"google","email":"a@gmail.com","createdAt":"2026-11-01T10:00:00.000Z"},{"provider":"apple","email":null,"createdAt":"2026-11-02T10:00:00.000Z"}]"#
        )
        #expect(identities.map(\.provider) == [.google, .apple])
        #expect(identities[1].email == nil)
    }

    @Test func decodesMeWithTheAccountFields() throws {
        let me = try decode(
            Me.self,
            #"{"email":"a@b.c","name":null,"totpEnabled":false,"hasPassword":false,"workspace":{"id":3,"name":"Noor Trading"},"role":"owner"}"#
        )
        #expect(me.name == nil)
        #expect(!me.hasPassword)
        #expect(me.workspace == Workspace(id: 3, name: "Noor Trading"))
        #expect(me.role == .owner)
    }

    @Test func decodesWorkspaceAndTotpState() throws {
        #expect(try decode(Workspace.self, #"{"id":1,"name":"New"}"#).name == "New")
        #expect(try decode(TotpState.self, #"{"totpEnabled":false}"#).totpEnabled == false)
    }
}

@Suite struct AuthErrorCodeTests {
    @Test func mapsEachCodeOnlyWithItsStatus() {
        #expect(APIError.server(status: 401, message: "totp_required").authCode == .totpRequired)
        #expect(APIError.server(status: 403, message: "email_unverified").authCode == .emailUnverified)
        #expect(APIError.server(status: 403, message: "registration_closed").authCode == .registrationClosed)
        #expect(
            APIError.server(status: 403, message: "recent_sign_in_required").authCode == .recentSignInRequired
        )
        #expect(APIError.server(status: 400, message: "email_unverified").authCode == nil)
        #expect(APIError.server(status: 403, message: "Something else").authCode == nil)
        #expect(APIError.offline.authCode == nil)
        #expect(CancellationError().authCode == nil)
    }

    @Test func codesReadAsSentencesAndOtherMessagesPassThrough() {
        #expect(APIError.server(status: 403, message: "registration_closed").localizedDescription == "Sign-up is closed right now.")
        #expect(
            APIError.server(status: 409, message: "You can't remove your last way to sign in").localizedDescription
                == "You can't remove your last way to sign in"
        )
    }

    @Test func loginErrorsComeFromTheirCodes() {
        #expect(LoginError(APIError.server(status: 401, message: "totp_required")) == .codeRequired)
        #expect(LoginError(APIError.server(status: 403, message: "email_unverified")) == .emailUnverified)
        #expect(LoginError(APIError.server(status: 401, message: "Email or password is incorrect")) == nil)
    }
}

@Suite struct AuthRequestBodyTests {
    private func object<T: Encodable>(_ value: T) throws -> [String: String] {
        let data = try JSONEncoder().encode(value)
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return raw.mapValues { "\($0)" }
    }

    private let credential = ProviderCredential(
        provider: .apple,
        idToken: "id.token.value",
        nonce: "raw-nonce-1234567890",
        authorizationCode: "c0de",
        name: "Sara Haddad"
    )

    @Test func registerUsesTheContractFields() throws {
        let body = try object(RegisterInput(email: "a@b.c", password: "long-password", name: nil, workspaceName: "Noor"))
        #expect(body == ["email": "a@b.c", "password": "long-password", "workspaceName": "Noor"])
    }

    @Test func oauthTokenAndLinkUseTheContractFields() throws {
        #expect(
            try object(OAuthTokenInput(credential, deviceName: "iOS: iPhone")) == [
                "idToken": "id.token.value",
                "nonce": "raw-nonce-1234567890",
                "authorizationCode": "c0de",
                "name": "Sara Haddad",
                "deviceName": "iOS: iPhone",
            ]
        )
        let google = ProviderCredential(provider: .google, idToken: "g", nonce: "n", authorizationCode: nil, name: nil)
        #expect(try object(OAuthLinkInput(google)) == ["idToken": "g", "nonce": "n"])
    }

    @Test func passwordConfirmAndWorkspaceUseTheContractFields() throws {
        #expect(try object(ChangePasswordInput(currentPassword: nil, newPassword: "n")) == ["newPassword": "n"])
        #expect(
            try object(ChangePasswordInput(currentPassword: "c", newPassword: "n"))
                == ["currentPassword": "c", "newPassword": "n"]
        )
        #expect(try object(ConfirmInput(password: "p", code: nil)) == ["password": "p"])
        #expect(try object(ConfirmInput(password: nil, code: "123456")) == ["code": "123456"])
        #expect(try object(EmailInput(email: "a@b.c")) == ["email": "a@b.c"])
        #expect(try object(WorkspaceInput(name: "New")) == ["name": "New"])
    }

    @Test func passwordRuleMatchesTheServer() {
        #expect(PasswordRule.problem("short") != nil)
        #expect(PasswordRule.problem(String(repeating: "a", count: 10)) == nil)
        #expect(PasswordRule.problem(String(repeating: "a", count: 201)) != nil)
    }
}

// MARK: - Calls

/// A stub of its own, because Swift Testing runs suites in parallel and `StubProtocol` is shared.
private final class AuthStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let authorization: String?
        let body: [String: String]
    }

    typealias Handler = @Sendable (Seen) -> (Int, String)
    static let handler = Mutex<Handler?>(nil)
    static let seen = Mutex<[Seen]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler.withLock({ $0 }) else { return }
        let seen = Seen(
            method: request.httpMethod ?? "",
            path: url.path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: Self.body(of: request)
        )
        Self.seen.withLock { $0.append(seen) }
        let (status, text) = handler(seen)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands the body over as a stream.
    private static func body(of request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return raw.mapValues { "\($0)" }
    }
}

private let meJSON =
    #"{"email":"a@b.c","name":"Sara","totpEnabled":false,"hasPassword":false,"workspace":{"id":3,"name":"Noor"},"role":"owner"}"#

@MainActor
@Suite(.serialized) struct AuthCallTests {
    private func client(tokens: any TokenStore) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthStub.self]
        return APIClient(
            baseURL: { URL(string: "https://example.test")! },
            session: URLSession(configuration: configuration),
            tokens: tokens
        )
    }

    private func stub(_ handler: @escaping AuthStub.Handler) {
        AuthStub.seen.withLock { $0 = [] }
        AuthStub.handler.withLock { $0 = handler }
    }

    private var seen: [AuthStub.Seen] { AuthStub.seen.withLock { $0 } }

    private let credential = ProviderCredential(
        provider: .google,
        idToken: "id.token.value",
        nonce: "raw-nonce-1234567890",
        authorizationCode: nil,
        name: nil
    )

    @Test func publicCallsSendNoToken() async throws {
        stub { seen in
            seen.path.hasSuffix("providers")
                ? (200, #"{"registration":true,"google":false,"apple":true,"googleIosClientId":null,"googleAndroidClientId":null}"#)
                : (202, #"{"ok":true}"#)
        }
        let api = client(tokens: MemoryTokenStore(StoredToken(id: 1, token: "secret")))
        _ = try await api.authProviders()
        try await api.register(RegisterInput(email: "a@b.c", password: "long-password", name: "S", workspaceName: "W"))
        try await api.resendVerification(email: "a@b.c")
        try await api.forgotPassword(email: "a@b.c")
        #expect(seen.map(\.path) == [
            "/api/v1/auth/providers", "/api/v1/auth/register",
            "/api/v1/auth/resend-verification", "/api/v1/auth/forgot-password",
        ])
        #expect(seen.allSatisfy { $0.authorization == nil })
        #expect(seen[1].body == ["email": "a@b.c", "password": "long-password", "name": "S", "workspaceName": "W"])
    }

    @Test func providerSignInStoresTheToken() async throws {
        stub { _ in (201, #"{"id":12,"name":"iOS: iPhone","token":"fresh"}"#) }
        let tokens = MemoryTokenStore()
        let session = Session(api: client(tokens: tokens), tokens: tokens)
        try await session.signIn(with: credential)
        #expect(session.state == .active)
        #expect(tokens.load() == StoredToken(id: 12, token: "fresh"))
        let call = try #require(seen.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/v1/auth/oauth/google/token")
        #expect(call.authorization == nil)
        #expect(call.body["idToken"] == "id.token.value")
        #expect(call.body["nonce"] == "raw-nonce-1234567890")
        #expect(call.body["deviceName"]?.hasPrefix("iOS: ") == true)
    }

    @Test func anUnverifiedEmailIsItsOwnError() async {
        stub { _ in (403, #"{"error":"email_unverified"}"#) }
        let tokens = MemoryTokenStore()
        let session = Session(api: client(tokens: tokens), tokens: tokens)
        await #expect(throws: LoginError.emailUnverified) {
            try await session.signIn(email: "a@b.c", password: "long-password", code: nil)
        }
        #expect(session.state == .signedOut)
    }

    @Test func accountCallsUseTheirRoutes() async throws {
        stub { seen in
            switch (seen.method, seen.path) {
            case ("GET", "/api/v1/auth/identities"): (200, "[]")
            case ("POST", "/api/v1/auth/oauth/apple/link"):
                (201, #"{"provider":"apple","email":null,"createdAt":"2026-11-05T00:00:00.000Z"}"#)
            case ("POST", "/api/v1/auth/totp/disable"): (200, #"{"totpEnabled":false}"#)
            case ("PUT", "/api/v1/workspace"): (200, #"{"id":3,"name":"New"}"#)
            case ("DELETE", "/api/v1/auth/identities/google"):
                (409, #"{"error":"You can't remove your last way to sign in"}"#)
            default: (200, #"{"ok":true}"#)
            }
        }
        let api = client(tokens: MemoryTokenStore(StoredToken(id: 1, token: "secret")))
        _ = try await api.identities()
        let apple = ProviderCredential(provider: .apple, idToken: "a", nonce: "n", authorizationCode: "c", name: "S")
        let linked = try await api.linkIdentity(apple)
        #expect(linked.provider == .apple)
        try await api.changePassword(current: nil, new: "long-password")
        _ = try await api.disableTotp(password: "pw", code: nil)
        #expect(try await api.renameWorkspace("New").name == "New")
        await #expect(throws: APIError.server(status: 409, message: "You can't remove your last way to sign in")) {
            try await api.unlinkIdentity(.google)
        }
        #expect(seen.allSatisfy { $0.authorization == "Bearer secret" })
        #expect(seen[1].body == ["idToken": "a", "nonce": "n", "authorizationCode": "c", "name": "S"])
        #expect(seen[2].path == "/api/v1/auth/password")
        #expect(seen[2].body == ["newPassword": "long-password"])
        #expect(seen[3].body == ["password": "pw"])
        #expect(seen[4].body == ["name": "New"])
    }

    @Test func deletingTheAccountSendsTheConfirmationAndSignsOut() async throws {
        stub { _ in (200, #"{"ok":true}"#) }
        let tokens = MemoryTokenStore(StoredToken(id: 1, token: "secret"))
        let session = Session(api: client(tokens: tokens), tokens: tokens) { true }
        await session.unlock()
        #expect(session.state == .active)
        try await session.deleteAccount(password: "pw", code: nil)
        let call = try #require(seen.first)
        #expect(call.method == "DELETE")
        #expect(call.path == "/api/v1/auth/account")
        #expect(call.body == ["password": "pw"])
        #expect(tokens.load() == nil)
        #expect(session.state == .signedOut)
    }

    @Test func aStaleSignInKeepsTheAccountAndTheToken() async {
        stub { _ in (403, #"{"error":"recent_sign_in_required"}"#) }
        let tokens = MemoryTokenStore(StoredToken(id: 1, token: "secret"))
        let session = Session(api: client(tokens: tokens), tokens: tokens) { true }
        await session.unlock()
        do {
            try await session.deleteAccount(password: nil, code: nil)
            Issue.record("Expected an error")
        } catch {
            #expect(error.authCode == .recentSignInRequired)
        }
        #expect(tokens.load() == StoredToken(id: 1, token: "secret"))
        #expect(session.state == .active)
    }

    @Test func signingInAgainReplacesTheTokenForTheSameAccount() async throws {
        let me = try JSONDecoder().decode(Me.self, from: Data(meJSON.utf8))
        stub { seen in
            switch (seen.method, seen.path) {
            case ("POST", _): (201, #"{"id":2,"name":"iOS","token":"fresh"}"#)
            case ("GET", _): (200, meJSON)
            default: (200, #"{"ok":true}"#)
            }
        }
        let tokens = MemoryTokenStore(StoredToken(id: 1, token: "old"))
        let session = Session(api: client(tokens: tokens), tokens: tokens) { true }
        try await session.reauthenticate(with: credential, as: me)
        #expect(tokens.load() == StoredToken(id: 2, token: "fresh"))
        // The old token is revoked with the new one.
        let revoke = try #require(seen.last)
        #expect(revoke.method == "DELETE")
        #expect(revoke.path == "/api/v1/auth/tokens/1")
        #expect(revoke.authorization == "Bearer fresh")
    }

    @Test func signingInAgainAsSomeoneElseKeepsTheOldToken() async throws {
        let me = try JSONDecoder().decode(Me.self, from: Data(meJSON.utf8))
        let other = meJSON.replacingOccurrences(of: "a@b.c", with: "other@b.c")
        stub { seen in
            switch (seen.method, seen.path) {
            case ("POST", _): (201, #"{"id":2,"name":"iOS","token":"fresh"}"#)
            case ("GET", _): (200, other)
            default: (200, #"{"ok":true}"#)
            }
        }
        let tokens = MemoryTokenStore(StoredToken(id: 1, token: "old"))
        let session = Session(api: client(tokens: tokens), tokens: tokens) { true }
        await #expect(throws: LoginError.differentAccount) {
            try await session.reauthenticate(with: credential, as: me)
        }
        #expect(tokens.load() == StoredToken(id: 1, token: "old"))
        let revoke = try #require(seen.last)
        #expect(revoke.path == "/api/v1/auth/tokens/2")
    }
}
