import Foundation

/// Minimal Audiobookshelf API client for the watch. Sends the watch's own access token and retries once
/// after a 401 with a refreshed one.
public struct AbsClient: Sendable {
    public let tokens: TokenManager
    public let deviceId: String
    public let clientVersion: String
    public let session: URLSession

    public var serverAddress: URL { tokens.serverAddress }

    public init(tokens: TokenManager, deviceId: String, clientVersion: String, session: URLSession = .shared) {
        self.tokens = tokens
        self.deviceId = deviceId
        self.clientVersion = clientVersion
        self.session = session
    }

    public enum ClientError: LocalizedError {
        case http(status: Int, body: String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let body): return "HTTP \(status): \(body.prefix(200))"
            }
        }
    }

    // MARK: Endpoints

    public func itemsInProgress(limit: Int = 25) async throws -> [LibraryItemSummary] {
        let response: ItemsInProgressResponse = try await get("api/me/items-in-progress", query: [URLQueryItem(name: "limit", value: String(limit))])
        return response.libraryItems
    }

    public func libraries() async throws -> [Library] {
        let response: LibrariesResponse = try await get("api/libraries")
        return response.libraries
    }

    /// `page` is 0-based.
    public func libraryItems(libraryId: String, page: Int, limit: Int = 30) async throws -> LibraryItemsPage {
        try await get("api/libraries/\(libraryId)/items", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort", value: "media.metadata.title"),
            URLQueryItem(name: "minified", value: "1")
        ])
    }

    public func item(id: String, episodeId: String? = nil) async throws -> LibraryItemDetail {
        var query = [URLQueryItem(name: "expanded", value: "1"), URLQueryItem(name: "include", value: "progress")]
        if let episodeId { query.append(URLQueryItem(name: "episode", value: episodeId)) }
        return try await get("api/items/\(id)", query: query)
    }

    /// Progress of every item the user started; list endpoints carry no progress of their own.
    public func allMediaProgress() async throws -> [MediaProgress] {
        let me: MeResponse = try await get("api/me")
        return me.mediaProgress
    }

    /// nil when the item was never started (the server answers 404).
    public func mediaProgress(libraryItemId: String, episodeId: String? = nil) async throws -> MediaProgress? {
        var path = "api/me/progress/\(libraryItemId)"
        if let episodeId { path += "/\(episodeId)" }
        do {
            return try await get(path)
        } catch ClientError.http(status: 404, body: _) {
            return nil
        }
    }

    /// Covers need no authentication.
    public func coverURL(libraryItemId: String, width: Int) -> URL {
        var url = serverAddress.appending(path: "api/items/\(libraryItemId)/cover")
        url.append(queryItems: [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "format", value: "jpeg")])
        return url
    }

    /// Opens a server playback session. Direct play is forced so tracks are the original files (byte-range downloadable).
    public func startPlayback(libraryItemId: String, episodeId: String? = nil, model: String) async throws -> PlaybackSession {
        var path = "api/items/\(libraryItemId)/play"
        if let episodeId { path += "/\(episodeId)" }
        let body = PlayRequest(
            deviceInfo: deviceInfo(model: model),
            forceDirectPlay: true,
            forceTranscode: false,
            mediaPlayer: "AVPlayer",
            supportedMimeTypes: ["audio/flac", "audio/mpeg", "audio/mp4", "audio/aac", "audio/x-aiff", "audio/x-m4b", "audio/x-m4a"]
        )
        return try await send("POST", path, body: body)
    }

    public func syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double) async throws {
        let body = SyncRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
        let _: EmptyResponse? = try await sendAllowingEmpty("POST", "api/session/\(id)/sync", body: body)
    }

    /// Closes the session; the optional final progress is applied like a sync.
    public func closeSession(id: String, currentTime: Double? = nil, timeListened: Double = 0, duration: Double? = nil) async throws {
        if let currentTime, let duration {
            let body = SyncRequest(currentTime: currentTime, timeListened: timeListened, duration: duration)
            let _: EmptyResponse? = try await sendAllowingEmpty("POST", "api/session/\(id)/close", body: body)
        } else {
            let _: EmptyResponse? = try await sendAllowingEmpty("POST", "api/session/\(id)/close", body: EmptyBody())
        }
    }

    /// Creates or updates a session played from downloaded files (`POST /api/session/local`), which also updates
    /// media progress unless the server's is newer.
    public func syncLocalSession(_ session: LocalSession, model: String) async throws {
        let body = LocalSessionBody(session: session, deviceInfo: deviceInfo(model: model))
        let _: EmptyResponse? = try await sendAllowingEmpty("POST", "api/session/local", body: body)
    }

    /// Request for a byte range of a track file (`contentUrl` of an `AudioTrack`); needs the access token.
    public func rangeRequest(contentUrl: String, range: Range<Int64>, token: String) -> URLRequest {
        var request = URLRequest(url: serverAddress.appending(path: contentUrl))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        return request
    }

    /// Unauthenticated stream URL, valid while the server session is open.
    public func publicTrackURL(sessionId: String, trackIndex: Int) -> URL {
        serverAddress.appending(path: "public/session/\(sessionId)/track/\(trackIndex)")
    }

    // MARK: Plumbing

    private struct DeviceInfo: Encodable {
        let deviceId: String
        let clientName: String
        let clientVersion: String
        let manufacturer: String
        let model: String
    }

    private func deviceInfo(model: String) -> DeviceInfo {
        DeviceInfo(deviceId: deviceId, clientName: "Abs Watch", clientVersion: clientVersion, manufacturer: "Apple", model: model)
    }

    /// The session's own fields plus `deviceInfo`, flat in one object.
    private struct LocalSessionBody: Encodable {
        let session: LocalSession
        let deviceInfo: DeviceInfo

        enum CodingKeys: String, CodingKey { case deviceInfo }

        func encode(to encoder: Encoder) throws {
            try session.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(deviceInfo, forKey: .deviceInfo)
        }
    }

    private struct PlayRequest: Encodable {
        let deviceInfo: DeviceInfo
        let forceDirectPlay: Bool
        let forceTranscode: Bool
        let mediaPlayer: String
        let supportedMimeTypes: [String]
    }

    private struct SyncRequest: Encodable {
        let currentTime: Double
        let timeListened: Double
        let duration: Double
    }

    private struct EmptyBody: Encodable {}
    private struct EmptyResponse: Decodable {}

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var url = serverAddress.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await perform(request("GET", path, query: query))
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T {
        var request = request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func sendAllowingEmpty<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T? {
        var request = request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await authorizedData(for: request)
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await authorizedData(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authorizedData(for request: URLRequest) async throws -> Data {
        var request = request
        let token = try await tokens.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let fresh = try await tokens.refresh(after: token)
            request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
        }
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}
