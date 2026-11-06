import Foundation
import Synchronization

enum APIError: LocalizedError, Equatable {
    /// The device could not reach the server.
    case offline
    /// The token is missing, revoked or expired.
    case signedOut
    case server(status: Int, message: String)
    /// The server sent something the app does not understand, usually a version mismatch.
    case unreadable

    var errorDescription: String? {
        switch self {
        case .offline: "You appear to be offline. Check your connection and try again."
        case .signedOut: "Log in to continue."
        case .server(let status, let message):
            AuthErrorCode(rawValue: message).flatMap { $0.status == status ? $0.message : nil } ?? message
        case .unreadable: "The server sent a response this app cannot read. Update the app and try again."
        }
    }
}

/// Talks to `/api/v1`. The bearer token is read from the Keychain for each request, so it is
/// never held in memory between calls.
final class APIClient: Sendable {
    private struct ErrorBody: Decodable {
        let error: String
    }

    private struct Empty: Encodable {}

    private let baseURL: @Sendable () -> URL
    private let session: URLSession
    private let tokens: any TokenStore
    private let unauthorizedHandler = Mutex<(@Sendable () -> Void)?>(nil)

    init(
        baseURL: @escaping @Sendable () -> URL = { ServerConfig.baseURL },
        session: URLSession = .shared,
        tokens: any TokenStore = KeychainTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokens = tokens
    }

    /// Called when the server rejects the stored token, so the app can return to login.
    func onUnauthorized(_ handler: @escaping @Sendable () -> Void) {
        unauthorizedHandler.withLock { $0 = handler }
    }

    func get<Response: Decodable>(
        _ path: String,
        query: [String: String?] = [:],
        authenticated: Bool = true
    ) async throws -> Response {
        try decode(try await send(request("GET", path, query: query, authenticated: authenticated), authenticated: authenticated))
    }

    func post<Response: Decodable>(_ path: String) async throws -> Response {
        try await post(path, body: Empty())
    }

    func post<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = request("POST", path, authenticated: authenticated)
        try attach(body, to: &request)
        return try decode(try await send(request, authenticated: authenticated))
    }

    func put<Response: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> Response {
        var request = request("PUT", path)
        try attach(body, to: &request)
        return try decode(try await send(request))
    }

    func patch<Response: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> Response {
        var request = request("PATCH", path)
        try attach(body, to: &request)
        return try decode(try await send(request))
    }

    func delete(_ path: String) async throws {
        let _: OkResponse = try decode(try await send(request("DELETE", path)))
    }

    func delete<Body: Encodable>(_ path: String, body: Body) async throws {
        var request = request("DELETE", path)
        try attach(body, to: &request)
        let _: OkResponse = try decode(try await send(request))
    }

    /// Fetches bytes, such as a PDF.
    func data(_ path: String) async throws -> Data {
        try await send(request("GET", path))
    }

    /// Sends a file as the `file` field of a multipart form.
    func upload<Response: Decodable>(
        _ path: String,
        file: Data,
        filename: String,
        contentType: String = "application/pdf"
    ) async throws -> Response {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = request("POST", path)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try decode(try await send(request))
    }

    private func request(
        _ method: String,
        _ path: String,
        query: [String: String?] = [:],
        authenticated: Bool = true
    ) -> URLRequest {
        var components = URLComponents(
            url: baseURL().appending(path: "api/v1").appending(path: path),
            resolvingAgainstBaseURL: false
        )
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty {
            components?.queryItems = items.sorted { $0.name < $1.name }
        }
        guard let url = components?.url else { preconditionFailure("Invalid API path: \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if authenticated, let token = tokens.load()?.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func attach<Body: Encodable>(_ body: Body, to request: inout URLRequest) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
    }

    private func send(_ request: URLRequest, authenticated: Bool = true) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.unreadable }
        if (200..<300).contains(http.statusCode) { return data }
        if http.statusCode == 401, authenticated {
            unauthorizedHandler.withLock { $0 }?()
            throw APIError.signedOut
        }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        throw APIError.server(
            status: http.statusCode,
            message: message ?? "Something went wrong on the server"
        )
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.unreadable
        }
    }
}
