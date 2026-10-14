import AbsWatchCore
import Foundation
import Observation

/// Drives the three spike tests:
/// 1. stream a track over LTE with a long forward buffer
/// 2. play a sparse local file that only holds a time window of the book
/// 3. fill that window with background vs. foreground range downloads
@MainActor @Observable
final class SpikeModel {
    static let downloadsRoot = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)

    let player = SpikePlayer()
    let background = RangeDownloader(background: true, root: downloadsRoot)
    let foreground = RangeDownloader(background: false, root: downloadsRoot)

    private(set) var items: [LibraryItemSummary] = []
    private(set) var session: PlaybackSession?
    private(set) var busy = false

    var windowMinutes = 60
    private(set) var windowStart: Double = 0
    private(set) var plannedBytes: Int64 = 0
    private(set) var presentBytes: Int64 = 0
    private(set) var allocatedBytes: Int64 = 0
    private var plans: [WindowPlanner.TrackPlan] = []
    private var progressTimer: Timer?

    var tokens: TokenManager? { AppModel.shared.tokens }
    var client: AbsClient? { AppModel.shared.client }

    init() {
        for downloader in [background, foreground] {
            downloader.makeRequest = { job, token in
                var request = URLRequest(url: job.contentUrlBase)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("bytes=\(job.lower)-\(job.upper - 1)", forHTTPHeaderField: "Range")
                return request
            }
            downloader.refreshToken = { failed in
                guard let tokens = await MainActor.run(body: { AppModel.shared.tokens }) else { return nil }
                return try? await tokens.refresh(after: failed)
            }
        }
    }

    /// Stops spike playback and downloads, e.g. before signing out.
    func reset() {
        player.stop()
        cancelDownloads()
        items = []
        session = nil
    }

    // MARK: Catalog and session

    func loadItems() async {
        guard let client else { return }
        await run("load items") {
            items = try await client.itemsInProgress()
            SpikeLog.shared.add("loaded \(items.count) items in progress")
        }
    }

    func open(_ item: LibraryItemSummary) async {
        guard let client else { return }
        await run("start session") {
            let session = try await client.startPlayback(libraryItemId: item.id, model: DeviceIdentity.model)
            self.session = session
            windowStart = session.currentTime
            SpikeLog.shared.add("session \(session.id.prefix(8)) method=\(session.playMethod) tracks=\(session.audioTracks.count) at \(SpikePlayer.format(session.currentTime))")
            for track in session.audioTracks.prefix(5) {
                SpikeLog.shared.add("  track \(track.index): \(track.ext) \(ByteCountFormatter.string(fromByteCount: track.metadata?.size ?? 0, countStyle: .file)) \(SpikePlayer.format(track.duration))")
            }
            refreshProgress()
        }
    }

    func closeSession() async {
        guard let client, let session else { return }
        player.stop()
        await run("close session") {
            try await client.closeSession(id: session.id)
            SpikeLog.shared.add("session closed")
        }
        self.session = nil
        progressTimer?.invalidate()
    }

    // MARK: Test 1: streaming

    func playStream(forwardBuffer: Double) async {
        guard let client, let session, let track = session.track(at: player.bookTime > 0 ? player.bookTime : session.currentTime) else { return }
        await activateAudio()
        let url = client.publicTrackURL(sessionId: session.id, trackIndex: track.index)
        player.load(url: url, description: "stream track \(track.index)", trackStartOffset: track.startOffset,
                    bookTime: player.bookTime > 0 ? player.bookTime : session.currentTime, forwardBuffer: forwardBuffer)
        player.play()
    }

    // MARK: Test 2 + 3: offline window

    func downloadWindow(inBackground: Bool) async {
        guard let tokens, let session, let itemId = session.libraryItemId else { return }
        guard let token = try? await tokens.accessToken() else { return }
        let tracks = session.audioTracks.map(\.plannerInfo)
        plans = WindowPlanner.plan(tracks: tracks, start: windowStart, duration: Double(windowMinutes) * 60)
        plannedBytes = plans.reduce(0) { $0 + $1.ranges.reduce(0) { $0 + Int64($1.count) } }
        SpikeLog.shared.add("window \(windowMinutes) min from \(SpikePlayer.format(windowStart)): \(plans.count) track(s), \(ByteCountFormatter.string(fromByteCount: plannedBytes, countStyle: .file))")

        let downloader = inBackground ? background : foreground
        for plan in plans {
            guard let track = session.audioTracks.first(where: { $0.index == plan.trackIndex }), let size = track.metadata?.size else { continue }
            do {
                try downloader.enqueue(path: localPath(itemId: itemId, track: track), contentUrl: tokens.serverAddress.appending(path: track.contentUrl).absoluteString,
                                       contentLength: size, ranges: plan.ranges, token: token)
            } catch {
                SpikeLog.shared.add("enqueue failed: \(error.localizedDescription)")
            }
        }
        startProgressTimer()
    }

    func cancelDownloads() {
        background.cancelAll()
        foreground.cancelAll()
        SpikeLog.shared.add("downloads cancelled")
    }

    func deleteDownloads() {
        cancelDownloads()
        try? FileManager.default.removeItem(at: Self.downloadsRoot)
        plannedBytes = 0
        presentBytes = 0
        allocatedBytes = 0
        SpikeLog.shared.add("downloads deleted")
    }

    /// Plays the sparse local file of the track containing the window start.
    /// `fromWindowEnd` seeks to 30 s before the planned window end, to observe what happens when playback runs into a hole.
    func playLocal(fromWindowEnd: Bool) async {
        guard let session, let itemId = session.libraryItemId else { return }
        let time = fromWindowEnd ? windowStart + Double(windowMinutes) * 60 - 30 : windowStart
        guard let track = session.track(at: time) else { return }
        let url = Self.downloadsRoot.appending(path: localPath(itemId: itemId, track: track))
        guard FileManager.default.fileExists(atPath: url.path) else {
            SpikeLog.shared.add("no local file for track \(track.index), download the window first")
            return
        }
        await activateAudio()
        player.load(url: url, description: "local track \(track.index)", trackStartOffset: track.startOffset, bookTime: time, forwardBuffer: 0)
        player.play()
    }

    // MARK: Helpers

    private func localPath(itemId: String, track: AudioTrack) -> String {
        "\(itemId)/track-\(track.index).\(track.ext.isEmpty ? "bin" : track.ext)"
    }

    private func activateAudio() async {
        do {
            let activated = try await player.activateAudioSession()
            SpikeLog.shared.add("audio session activated=\(activated)")
        } catch {
            SpikeLog.shared.add("audio session error: \(error.localizedDescription)")
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProgress() }
        }
    }

    private func refreshProgress() {
        guard let session, let itemId = session.libraryItemId else { return }
        var present: Int64 = 0
        var allocated: Int64 = 0
        for plan in plans {
            guard let track = session.audioTracks.first(where: { $0.index == plan.trackIndex }), let size = track.metadata?.size,
                  let file = try? background.file(path: localPath(itemId: itemId, track: track), contentLength: size) else { continue }
            // Re-open to pick up writes made by either downloader
            let fresh = (try? SparseTrackFile(dataURL: file.dataURL, contentLength: size)) ?? file
            for range in plan.ranges {
                present += Int64(range.count) - fresh.missing(in: range).reduce(0) { $0 + Int64($1.count) }
            }
            allocated += fresh.allocatedBytes
        }
        presentBytes = present
        allocatedBytes = allocated
        if plannedBytes > 0, present >= plannedBytes, progressTimer != nil {
            SpikeLog.shared.add("window fully downloaded (\(ByteCountFormatter.string(fromByteCount: allocated, countStyle: .file)) on disk)")
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func run(_ label: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch TokenManager.TokenError.signedOut {
            AppModel.shared.handle(TokenManager.TokenError.signedOut)
        } catch {
            SpikeLog.shared.add("\(label) failed: \(error.localizedDescription)")
        }
    }
}
