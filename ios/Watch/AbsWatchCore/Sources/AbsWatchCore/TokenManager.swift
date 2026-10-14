import Foundation

/// Owns the watch's tokens. Access tokens live 1 h, refresh tokens 30 days and are rotated by the server on every
/// refresh (the old one stays valid for a short grace period). So:
/// - only one refresh runs at a time; concurrent 401s wait for it,
/// - the rotated refresh token is persisted before the new access token is handed out,
/// - only an explicit 401/403 from /auth/refresh signs the watch out; network errors keep the credentials.
public actor TokenManager {
    public enum TokenError: LocalizedError, Equatable {
        case signedOut
        case refreshFailed(String)

        public var errorDescription: String? {
            switch self {
            case .signedOut: return "Signed out, pair with the iPhone again"
            case .refreshFailed(let reason): return "Token refresh failed: \(reason)"
            }
        }
    }

    public nonisolated let serverAddress: URL
    private var credentials: Credentials?
    private let store: CredentialStore
    private let session: URLSession
    private var refreshTask: Task<String, Error>?

    public init(credentials: Credentials, store: CredentialStore, session: URLSession = .shared) {
        self.serverAddress = credentials.serverAddress
        self.credentials = credentials
        self.store = store
        self.session = session
    }

    public var current: Credentials? { credentials }

    public func accessToken() throws -> String {
        guard let credentials else { throw TokenError.signedOut }
        return credentials.accessToken
    }

    /// Returns a fresh access token after `failedToken` was rejected with 401.
    /// If another caller already refreshed, the newer token is returned without a second refresh.
    public func refresh(after failedToken: String) async throws -> String {
        guard let credentials else { throw TokenError.signedOut }
        if credentials.accessToken != failedToken { return credentials.accessToken }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { try await performRefresh(credentials) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Ends this watch's server session (only this one) and forgets the credentials.
    public func signOut() async {
        if let credentials {
            var request = URLRequest(url: serverAddress.appending(path: "logout"))
            request.httpMethod = "POST"
            request.setValue(credentials.refreshToken, forHTTPHeaderField: "x-refresh-token")
            _ = try? await session.data(for: request)
        }
        credentials = nil
        store.delete()
    }

    private func performRefresh(_ old: Credentials) async throws -> String {
        var request = URLRequest(url: serverAddress.appending(path: "auth/refresh"))
        request.httpMethod = "POST"
        request.setValue(old.refreshToken, forHTTPHeaderField: "x-refresh-token")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TokenError.refreshFailed(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            credentials = nil
            store.delete()
            throw TokenError.signedOut
        }
        guard status == 200,
              let user = try? JSONDecoder().decode(LoginResponse.self, from: data).user,
              let accessToken = user.accessToken, !accessToken.isEmpty,
              let refreshToken = user.refreshToken, !refreshToken.isEmpty
        else {
            throw TokenError.refreshFailed("HTTP \(status)")
        }

        var updated = old
        updated.accessToken = accessToken
        updated.refreshToken = refreshToken
        try store.save(updated)
        credentials = updated
        return accessToken
    }
}
