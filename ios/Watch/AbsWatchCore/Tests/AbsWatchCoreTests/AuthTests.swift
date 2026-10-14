import Foundation
import Testing
@testable import AbsWatchCore

/// Suites that use `StubProtocol` live in this parent so they run one test at a time: the handler is global.
@Suite(.serialized) enum StubbedNetwork {}

/// Answers requests from a per-test handler.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler?(request) ?? (500, Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MemoryStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Credentials?
    init(_ credentials: Credentials? = nil) { stored = credentials }
    func load() -> Credentials? { lock.withLock { stored } }
    func save(_ credentials: Credentials) throws { lock.withLock { stored = credentials } }
    func delete() { lock.withLock { stored = nil } }
}

private let server = URL(string: "https://abs.example.com")!
private let initial = Credentials(serverAddress: server, serverName: "Home", username: "stephan", accessToken: "a1", refreshToken: "r1")

private func loginJSON(access: String, refresh: String) -> Data {
    Data(#"{"user":{"username":"stephan","accessToken":"\#(access)","refreshToken":"\#(refresh)"}}"#.utf8)
}

extension StubbedNetwork {
@Suite struct TokenManagerTests {
    init() {
        StubProtocol.requests = []
        StubProtocol.handler = nil
    }

    @Test func refreshRotatesAndPersistsBothTokens() async throws {
        StubProtocol.handler = { request in
            #expect(request.url?.path == "/auth/refresh")
            #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "r1")
            return (200, loginJSON(access: "a2", refresh: "r2"))
        }
        let store = MemoryStore(initial)
        let tokens = TokenManager(credentials: initial, store: store, session: StubProtocol.session())

        #expect(try await tokens.refresh(after: "a1") == "a2")
        #expect(store.load()?.refreshToken == "r2")
        #expect(store.load()?.accessToken == "a2")
    }

    @Test func concurrentRefreshesHitTheServerOnce() async throws {
        StubProtocol.handler = { _ in (200, loginJSON(access: "a2", refresh: "r2")) }
        let tokens = TokenManager(credentials: initial, store: MemoryStore(initial), session: StubProtocol.session())

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await tokens.refresh(after: "a1") } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results == Array(repeating: "a2", count: 5))
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func rejectedRefreshSignsOut() async throws {
        StubProtocol.handler = { _ in (401, Data(#"{"error":"Invalid refresh token"}"#.utf8)) }
        let store = MemoryStore(initial)
        let tokens = TokenManager(credentials: initial, store: store, session: StubProtocol.session())

        await #expect(throws: TokenManager.TokenError.signedOut) { try await tokens.refresh(after: "a1") }
        #expect(store.load() == nil)
        await #expect(throws: TokenManager.TokenError.signedOut) { try await tokens.accessToken() }
    }

    @Test func serverErrorKeepsCredentials() async throws {
        StubProtocol.handler = { _ in (502, Data()) }
        let store = MemoryStore(initial)
        let tokens = TokenManager(credentials: initial, store: store, session: StubProtocol.session())

        await #expect(throws: TokenManager.TokenError.refreshFailed("HTTP 502")) { try await tokens.refresh(after: "a1") }
        #expect(store.load() == initial)
        #expect(try await tokens.accessToken() == "a1")
    }

    @Test func clientRetriesOnceWithRefreshedToken() async throws {
        StubProtocol.handler = { request in
            switch (request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("/api/me/items-in-progress", "Bearer a1"): return (401, Data())
            case ("/auth/refresh", _): return (200, loginJSON(access: "a2", refresh: "r2"))
            case ("/api/me/items-in-progress", "Bearer a2"): return (200, Data(#"{"libraryItems":[]}"#.utf8))
            default: return (500, Data())
            }
        }
        let tokens = TokenManager(credentials: initial, store: MemoryStore(initial), session: StubProtocol.session())
        let client = AbsClient(tokens: tokens, deviceId: "watch-test", clientVersion: "0", session: StubProtocol.session())

        #expect(try await client.itemsInProgress().isEmpty)
        #expect(StubProtocol.requests.map { $0.url?.path ?? "" } == ["/api/me/items-in-progress", "/auth/refresh", "/api/me/items-in-progress"])
    }

    @Test func pairingPollsUntilAuthorized() async throws {
        var polls = 0
        StubProtocol.handler = { request in
            #expect(request.url?.path == "/auth/device-code/poll")
            polls += 1
            return polls < 3 ? (200, Data(#"{"status":"pending"}"#.utf8)) : (200, loginJSON(access: "w1", refresh: "wr1"))
        }
        let grant = DevicePairing.PhoneGrant(serverAddress: server, serverName: "Home", username: "stephan", deviceCode: String(repeating: "a", count: 64))
        let credentials = try await DevicePairing.pollForCredentials(grant: grant, session: StubProtocol.session(), interval: .milliseconds(10))
        #expect(credentials.accessToken == "w1")
        #expect(credentials.refreshToken == "wr1")
        #expect(credentials.serverName == "Home")
        #expect(polls == 3)
    }

    @Test func pairingStopsWhenCodeExpired() async throws {
        StubProtocol.handler = { _ in (410, Data(#"{"status":"expired"}"#.utf8)) }
        let grant = DevicePairing.PhoneGrant(serverAddress: server, serverName: nil, username: nil, deviceCode: "x")
        await #expect(throws: DevicePairing.PairingError.expired) {
            try await DevicePairing.pollForCredentials(grant: grant, session: StubProtocol.session(), interval: .milliseconds(10))
        }
    }

    @Test func phoneErrorReplyIsSurfaced() {
        #expect(throws: DevicePairing.PairingError.phone("Log in first")) { try DevicePairing.PhoneGrant(reply: ["error": "Log in first"]) }
        let grant = try? DevicePairing.PhoneGrant(reply: ["serverAddress": "https://abs.example.com", "deviceCode": "abc", "serverName": "Home"])
        #expect(grant?.deviceCode == "abc")
    }
}
}
