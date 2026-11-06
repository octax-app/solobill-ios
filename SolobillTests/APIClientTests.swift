import Foundation
import Synchronization
import Testing

@testable import Solobill

/// Serves canned responses and records what the client sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    static let handler = Mutex<Handler?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler.withLock({ $0 }), let url = request.url else { return }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            client?.urlProtocol(self, didReceive: try #require(response), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class MemoryTokenStore: TokenStore, Sendable {
    private let stored = Mutex<StoredToken?>(nil)

    init(_ token: StoredToken? = nil) { stored.withLock { $0 = token } }
    func load() -> StoredToken? { stored.withLock { $0 } }
    func save(_ token: StoredToken) throws { stored.withLock { $0 = token } }
    func clear() { stored.withLock { $0 = nil } }
}

@MainActor
@Suite(.serialized) struct APIClientTests {
    private func client(tokens: any TokenStore = MemoryTokenStore(StoredToken(id: 7, token: "secret"))) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(
            baseURL: { URL(string: "https://example.test")! },
            session: URLSession(configuration: configuration),
            tokens: tokens
        )
    }

    private func stub(_ handler: @escaping StubProtocol.Handler) {
        StubProtocol.handler.withLock { $0 = handler }
    }

    @Test func sendsTheBearerTokenAndQuery() async throws {
        let seen = Mutex<URLRequest?>(nil)
        stub { request in
            seen.withLock { $0 = request }
            return (200, Data("[]".utf8))
        }
        let rows = try await client().customers(search: "al noor")
        #expect(rows.isEmpty)
        let request = try #require(seen.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.url?.absoluteString == "https://example.test/api/v1/customers?q=al%20noor")
    }

    @Test func showsTheServersErrorMessage() async {
        stub { _ in (409, Data(#"{"error":"Only drafts can be changed."}"#.utf8)) }
        await #expect(throws: APIError.server(status: 409, message: "Only drafts can be changed.")) {
            try await self.client().issue(id: 1)
        }
    }

    @Test func reportsOfflineWhenTheConnectionFails() async {
        stub { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: APIError.offline) {
            _ = try await self.client().overview()
        }
    }

    @Test func aRejectedTokenSignsTheOwnerOut() async throws {
        stub { _ in (401, Data(#"{"error":"Log in to continue"}"#.utf8)) }
        let tokens = MemoryTokenStore(StoredToken(id: 7, token: "revoked"))
        let api = client(tokens: tokens)
        let session = Session(api: api, tokens: tokens)
        await #expect(throws: APIError.signedOut) {
            _ = try await api.overview()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .signedOut)
        #expect(tokens.load() == nil)
    }

    @Test func asksForTheCodeWhenTwoStepLoginIsOn() async {
        stub { _ in (401, Data(#"{"error":"totp_required"}"#.utf8)) }
        let tokens = MemoryTokenStore()
        let session = Session(api: client(tokens: tokens), tokens: tokens)
        await #expect(throws: LoginError.self) {
            try await session.signIn(email: "a@b.c", password: "x", code: nil)
        }
        #expect(session.state == .signedOut)
    }

    @Test func aWrongPasswordIsShownAndDoesNotSignOut() async {
        stub { _ in (401, Data(#"{"error":"Email or password is incorrect"}"#.utf8)) }
        let tokens = MemoryTokenStore()
        let session = Session(api: client(tokens: tokens), tokens: tokens)
        await #expect(throws: APIError.server(status: 401, message: "Email or password is incorrect")) {
            try await session.signIn(email: "a@b.c", password: "x", code: nil)
        }
    }

    @Test func signingInStoresTheTokenAndSigningOutRevokesIt() async throws {
        let revoked = Mutex<String?>(nil)
        stub { request in
            if request.httpMethod == "DELETE" {
                revoked.withLock { $0 = request.url?.path }
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            return (201, Data(#"{"id":9,"name":"iPhone","token":"fresh"}"#.utf8))
        }
        let tokens = MemoryTokenStore()
        let session = Session(api: client(tokens: tokens), tokens: tokens)
        try await session.signIn(email: "a@b.c", password: "x", code: nil)
        #expect(session.state == .active)
        #expect(tokens.load() == StoredToken(id: 9, token: "fresh"))
        await session.signOut()
        #expect(revoked.withLock { $0 } == "/api/v1/auth/tokens/9")
        #expect(tokens.load() == nil)
        #expect(session.state == .signedOut)
    }

    @Test func aCancelledPromptIsNotRepeatedUntilTheOwnerAsks() async {
        let prompts = Mutex(0)
        let tokens = MemoryTokenStore(StoredToken(id: 1, token: "a"))
        let session = Session(api: client(tokens: tokens), tokens: tokens) {
            prompts.withLock { $0 += 1 }
            return false
        }
        #expect(session.state == .locked)
        await session.unlockAutomatically()
        await session.unlockAutomatically()
        #expect(prompts.withLock { $0 } == 1)
        #expect(session.state == .locked)
        await session.unlock()
        #expect(prompts.withLock { $0 } == 2)
    }

    @Test func lockingAgainPromptsAgain() async {
        let prompts = Mutex(0)
        let tokens = MemoryTokenStore(StoredToken(id: 1, token: "a"))
        let session = Session(api: client(tokens: tokens), tokens: tokens) {
            prompts.withLock { $0 += 1 }
            return true
        }
        await session.unlockAutomatically()
        #expect(session.state == .active)
        session.lock()
        #expect(session.state == .locked)
        await session.unlockAutomatically()
        #expect(session.state == .active)
        #expect(prompts.withLock { $0 } == 2)
    }

    @Test func keychainRoundTrips() throws {
        let store = KeychainTokenStore()
        store.clear()
        #expect(store.load() == nil)
        try store.save(StoredToken(id: 1, token: "a"))
        try store.save(StoredToken(id: 2, token: "b"))
        #expect(store.load() == StoredToken(id: 2, token: "b"))
        store.clear()
        #expect(store.load() == nil)
    }
}
