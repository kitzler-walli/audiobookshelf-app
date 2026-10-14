import Foundation

/// Reports listening progress of an open server playback session, like the iPhone app does:
/// every 15 s while playing, plus on pause and when closing.
///
/// Listened seconds are accumulated locally and only deducted once the server confirmed them, so a failed sync
/// (no LTE) loses nothing; the next successful sync carries the total. A 404 means the server no longer has the
/// session (restart or stale cleanup); the caller should open a new one and continue.
public actor PlaybackSync {
    public enum Outcome: Equatable, Sendable {
        case synced
        case failed
        case sessionGone
    }

    public static let syncInterval: Duration = .seconds(15)

    private let client: AbsClient
    public private(set) var sessionId: String
    private let duration: Double
    private var pendingListened: Double = 0
    private var lastSync: ContinuousClock.Instant?

    public init(client: AbsClient, sessionId: String, duration: Double) {
        self.client = client
        self.sessionId = sessionId
        self.duration = duration
    }

    public var unsyncedSeconds: Double { pendingListened }

    /// Adds actually listened (wall clock) time, independent of playback speed or seeking.
    public func addListened(_ seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        pendingListened += seconds
    }

    /// Syncs if the interval has passed since the last attempt. Returns nil when it was not due.
    public func syncIfDue(currentTime: Double) async -> Outcome? {
        if let lastSync, ContinuousClock.now - lastSync < Self.syncInterval { return nil }
        return await sync(currentTime: currentTime)
    }

    public func sync(currentTime: Double) async -> Outcome {
        lastSync = ContinuousClock.now
        let reported = pendingListened
        do {
            try await client.syncSession(id: sessionId, currentTime: currentTime, timeListened: reported, duration: duration)
            pendingListened -= reported
            return .synced
        } catch AbsClient.ClientError.http(status: 404, body: _) {
            return .sessionGone
        } catch {
            return .failed
        }
    }

    /// Final sync and close. Best effort: a closed or vanished session is fine.
    public func close(currentTime: Double) async {
        let reported = pendingListened
        do {
            try await client.closeSession(id: sessionId, currentTime: currentTime, timeListened: reported, duration: duration)
            pendingListened -= reported
        } catch {
            // Progress up to the last successful sync is already on the server
        }
    }

    /// Continues reporting into a newly opened session; unsynced listening time is carried over.
    public func replaceSession(id: String) {
        sessionId = id
        lastSync = nil
    }
}
