import Foundation

/// Reports listening time and position while playing. `PlaybackSync` does it for server sessions (streaming),
/// `LocalSessionSync` for downloaded items.
public protocol ListeningReporter: Actor {
    func addListened(_ seconds: Double)
    /// Syncs if the interval has passed since the last attempt. Returns nil when it was not due.
    func syncIfDue(currentTime: Double) async -> PlaybackSync.Outcome?
    func sync(currentTime: Double) async -> PlaybackSync.Outcome
    func close(currentTime: Double) async
}

extension PlaybackSync: ListeningReporter {}

/// A listening session played from downloaded files, in the format of `POST /api/session/local` (like the iPhone
/// app's downloads). The server creates the session on the first upload and updates it on later ones, so uploading
/// the same session again is harmless. Media progress is only taken when it is newer than the server's.
public struct LocalSession: Codable, Sendable, Identifiable {
    public let id: String
    public let libraryItemId: String
    public let episodeId: String?
    public let mediaType: String
    public let displayTitle: String
    public let displayAuthor: String?
    public let duration: Double
    public let playMethod: Int
    public let mediaPlayer: String
    /// Local calendar day the session started, for the server's listening stats
    public let date: String
    public let dayOfWeek: String
    public var timeListening: Double
    public let startTime: Double
    public var currentTime: Double
    /// Epoch milliseconds
    public let startedAt: Double
    public var updatedAt: Double
    /// Watch-only: playback ended, the session can be deleted once uploaded
    public var isClosed: Bool

    public init(item: DownloadedItem, startTime: Double, now: Date = Date()) {
        id = UUID().uuidString.lowercased()
        libraryItemId = item.libraryItemId
        episodeId = item.episodeId
        mediaType = item.isPodcast ? "podcast" : "book"
        displayTitle = item.title
        displayAuthor = item.author
        duration = item.duration
        playMethod = PlayMethod.local
        mediaPlayer = "AVPlayer"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        date = formatter.string(from: now)
        formatter.dateFormat = "EEEE"
        dayOfWeek = formatter.string(from: now)
        timeListening = 0
        self.startTime = startTime
        currentTime = startTime
        startedAt = (now.timeIntervalSince1970 * 1000).rounded()
        updatedAt = startedAt
        isClosed = false
    }
}

/// Local sessions waiting for upload, one JSON file each.
public struct LocalSessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ session: LocalSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: url(for: session.id), options: .atomic)
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public func all() -> [LocalSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(LocalSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Uploads stored sessions, e.g. after coming back online. Sessions other than `activeId` are finished
    /// (closed, or the app was quit while playing) and are deleted once the server has them.
    /// Returns the number of sessions uploaded.
    @discardableResult
    public func uploadPending(client: AbsClient, model: String, excluding activeId: String? = nil) async -> Int {
        var uploaded = 0
        for session in all() where session.id != activeId {
            switch await LocalSessionSync.upload(session, client: client, model: model) {
            case .synced, .sessionGone:
                delete(id: session.id)
                uploaded += 1
            case .failed:
                break
            }
        }
        return uploaded
    }

    private func url(for id: String) -> URL {
        directory.appending(path: "\(id).json")
    }
}

/// Reports a local session: every change is saved to disk first, so nothing is lost when the watch is offline or the
/// app is quit, then uploaded every 15 s when possible.
public actor LocalSessionSync: ListeningReporter {
    public private(set) var session: LocalSession
    private let client: AbsClient
    private let store: LocalSessionStore
    private let model: String
    private var lastSync: ContinuousClock.Instant?

    public init(session: LocalSession, client: AbsClient, store: LocalSessionStore, model: String) {
        self.session = session
        self.client = client
        self.store = store
        self.model = model
        try? store.save(session)
    }

    public func addListened(_ seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        session.timeListening += seconds
    }

    public func syncIfDue(currentTime: Double) async -> PlaybackSync.Outcome? {
        if let lastSync, ContinuousClock.now - lastSync < PlaybackSync.syncInterval { return nil }
        return await sync(currentTime: currentTime)
    }

    public func sync(currentTime: Double) async -> PlaybackSync.Outcome {
        lastSync = ContinuousClock.now
        update(currentTime: currentTime)
        return await Self.upload(session, client: client, model: model)
    }

    public func close(currentTime: Double) async {
        update(currentTime: currentTime)
        session.isClosed = true
        try? store.save(session)
        if await Self.upload(session, client: client, model: model) != .failed {
            store.delete(id: session.id)
        }
    }

    private func update(currentTime: Double) {
        session.currentTime = currentTime
        session.updatedAt = (Date().timeIntervalSince1970 * 1000).rounded()
        try? store.save(session)
    }

    /// `.sessionGone` means the server will never accept it (item deleted), so it should be dropped.
    static func upload(_ session: LocalSession, client: AbsClient, model: String) async -> PlaybackSync.Outcome {
        do {
            try await client.syncLocalSession(session, model: model)
            return .synced
        } catch AbsClient.ClientError.http(status: let status, body: let body) where status == 404 || body.contains("not found") {
            return .sessionGone
        } catch {
            return .failed
        }
    }
}
