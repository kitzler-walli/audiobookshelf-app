import AbsWatchCore
import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Plays a book and keeps the server in sync, like the iPhone app.
///
/// Streaming: opens a server playback session, streams its tracks, reports progress every 15 s and on pause, and
/// closes it on stop. Downloaded items: plays the local files and records a local session that is uploaded whenever
/// the watch is online. When playback reaches bytes that are not downloaded yet, the missing part is fetched first.
@MainActor @Observable
final class PlayerController {
    static let shared = PlayerController()

    static let playbackRates: [Float] = [0.8, 1.0, 1.2, 1.5, 1.75, 2.0]
    /// After a longer pause another device may have moved on; check the server before resuming.
    private static let resumeCheckAfter: TimeInterval = 30

    /// Server session while streaming
    private(set) var session: PlaybackSession?
    /// The download being played from local files
    private(set) var downloadedItem: DownloadedItem?
    /// Its local session, which is uploaded by its own reporter
    private(set) var localSessionId: String?
    private(set) var libraryItemId: String?
    private(set) var episodeId: String?
    private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { DownloadManager.shared.playbackChanged() } }
    }
    private(set) var isLoading = false
    private(set) var isBuffering = false
    private(set) var bookTime: Double = 0
    private(set) var bufferedAhead: Double = 0
    private(set) var errorMessage: String?
    private(set) var rate: Float = 1.0

    var isActive: Bool { session != nil || downloadedItem != nil }
    var isLocal: Bool { downloadedItem != nil }
    var title: String { session?.displayTitle ?? downloadedItem?.title ?? "" }
    var author: String? { session?.displayAuthor ?? downloadedItem?.author }
    var duration: Double { session?.duration ?? downloadedItem?.duration ?? 0 }
    var chapters: [Chapter] { session?.chapters ?? downloadedItem?.chapters ?? [] }
    var currentChapter: Chapter? { chapters.last { $0.start <= bookTime + 0.5 } }

    private let player = AVQueuePlayer()
    private var client: AbsClient?
    private var reporter: (any ListeningReporter)?
    private var tracks: [AudioTrack] = []
    private var lastPositionSave: Date?
    private var lastTopUp: Date?
    private var tracksByItem: [ObjectIdentifier: AudioTrack] = [:]
    private var timeObserver: Any?
    private var lastTick: Date?
    private var pausedAt: Date?
    private var interruptedWhilePlaying = false
    private var observers: [NSObjectProtocol] = []
    private var artwork: MPMediaItemArtwork?

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        setupRemoteCommands()
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                self.itemDidPlayToEnd(item)
            }
        })
        // Another app, a call or Siri took the audio session: pause (and sync) now, resume if the system recommends it
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.interruptedWhilePlaying = true
                self.pause()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            MainActor.assumeIsolated {
                guard let self, self.interruptedWhilePlaying else { return }
                self.interruptedWhilePlaying = false
                if context?.recommendation == .shouldResume {
                    Task { await self.resume() }
                }
            }
        })
    }

    // MARK: - Starting playback

    /// Opens (or resumes) the item. `startTime` overrides the server position, e.g. when a chapter is tapped.
    func play(libraryItemId: String, episodeId: String? = nil, startTime: Double? = nil, client: AbsClient) async {
        if self.libraryItemId == libraryItemId, self.episodeId == episodeId, isActive {
            if let startTime { seek(to: startTime) }
            await resume()
            return
        }

        await stop()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard try await activateAudioSession() else {
                errorMessage = "Connect Bluetooth headphones to listen"
                return
            }
            if let item = DownloadManager.shared.item(libraryItemId: libraryItemId, episodeId: episodeId) {
                await playDownloaded(item, startTime: startTime, client: client)
                return
            }
            let session = try await client.startPlayback(libraryItemId: libraryItemId, episodeId: episodeId, model: DeviceIdentity.model)
            self.client = client
            self.session = session
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            tracks = session.sortedTracks
            reporter = PlaybackSync(client: client, sessionId: session.id, duration: session.duration)
            AppLog.shared.add("streaming \(session.displayTitle ?? libraryItemId) from \(Self.format(startTime ?? session.currentTime))")
            begin(at: startTime ?? session.currentTime, client: client)
        } catch {
            errorMessage = error.localizedDescription
            AppLog.shared.add("play failed: \(error.localizedDescription)")
        }
    }

    /// Plays from the watch. Starts at the newer of the watch's and the server's position (when reachable).
    private func playDownloaded(_ item: DownloadedItem, startTime: Double?, client: AbsClient) async {
        var start = startTime ?? item.position ?? 0
        if startTime == nil, let progress = await Self.serverProgress(for: item, client: client) {
            let serverUpdate = Date(timeIntervalSince1970: progress.lastUpdate / 1000)
            if serverUpdate > item.positionUpdatedAt ?? .distantPast {
                start = progress.isFinished ? 0 : progress.currentTime
            }
        }
        if start >= item.duration - 5 { start = 0 }

        let manager = DownloadManager.shared
        if manager.playableEnd(item, from: start) < min(item.duration, start + 5) {
            AppLog.shared.add("\(Self.format(start)) of \(item.title) is not downloaded, fetching it")
            guard await manager.ensurePlayable(item.id, from: start) else {
                errorMessage = "This part is not downloaded. Connect to the internet to continue."
                return
            }
        }

        self.client = client
        downloadedItem = item
        libraryItemId = item.libraryItemId
        episodeId = item.episodeId
        tracks = item.sortedTracks
        let localSession = LocalSession(item: item, startTime: start)
        localSessionId = localSession.id
        reporter = LocalSessionSync(session: localSession, client: client, store: AppModel.shared.localSessions, model: DeviceIdentity.model)
        AppLog.shared.add("playing downloaded \(item.title) from \(Self.format(start))")
        begin(at: start, client: client)
        Task { await AppModel.shared.uploadPendingSessions() }
    }

    private func begin(at time: Double, client: AbsClient) {
        player.actionAtItemEnd = isLocal ? .pause : .advance
        loadQueue(at: time)
        startTimeObserver()
        if let libraryItemId { loadArtwork(libraryItemId: libraryItemId, client: client) }
        player.play()
        player.rate = rate
        pausedAt = nil
        updateNowPlaying()
    }

    /// The server's position, or nil when offline or slow (a walk with weak LTE should not block playback).
    private static func serverProgress(for item: DownloadedItem, client: AbsClient) async -> MediaProgress? {
        await withTaskGroup(of: MediaProgress?.self) { group in
            group.addTask { try? await client.mediaProgress(libraryItemId: item.libraryItemId, episodeId: item.episodeId) }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            Task { await resume() }
        }
    }

    func pause() {
        guard isActive else { return }
        player.pause()
        tick()
        isPlaying = false
        pausedAt = Date()
        updateNowPlaying()
        Task { await syncNow() }
    }

    func resume() async {
        guard isActive else { return }
        if let pausedAt, Date().timeIntervalSince(pausedAt) > Self.resumeCheckAfter {
            await applyNewerServerProgress()
        }
        if let item = downloadedItem, DownloadManager.shared.playableEnd(item, from: bookTime) < min(duration, bookTime + 5) {
            await continueAfterGap(at: bookTime)
            return
        }
        errorMessage = nil
        _ = try? await activateAudioSession()
        player.play()
        player.rate = rate
        pausedAt = nil
        lastTick = Date()
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: bookTime + seconds)
    }

    func seek(to time: Double) {
        guard isActive else { return }
        let target = min(max(0, time), max(0, duration - 1))
        if let item = downloadedItem, DownloadManager.shared.playableEnd(item, from: target) < min(duration, target + 5) {
            let wasPlaying = isPlaying
            player.pause()
            bookTime = target
            if wasPlaying { Task { await continueAfterGap(at: target) } }
            updateNowPlaying()
            return
        }
        if let track = currentTrack, track.startOffset <= target, target < track.startOffset + track.duration {
            player.seek(to: CMTime(seconds: target - track.startOffset, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let wasPlaying = isPlaying
            loadQueue(at: target)
            if wasPlaying { player.play(); player.rate = rate }
        }
        bookTime = target
        updateNowPlaying()
    }

    func nextChapter() {
        guard let next = chapters.first(where: { $0.start > bookTime + 0.5 }) else { return }
        seek(to: next.start)
    }

    /// Like a CD player: back to the start of the chapter, or to the previous one when already near its start.
    func previousChapter() {
        guard let current = currentChapter else { return seek(to: 0) }
        if bookTime - current.start > 3 {
            seek(to: current.start)
        } else if let previous = chapters.last(where: { $0.start < current.start }) {
            seek(to: previous.start)
        } else {
            seek(to: 0)
        }
    }

    func cycleRate() {
        let index = Self.playbackRates.firstIndex(of: rate) ?? 1
        rate = Self.playbackRates[(index + 1) % Self.playbackRates.count]
        if isPlaying { player.rate = rate }
        updateNowPlaying()
    }

    /// Final sync, closes the server session and releases the audio session.
    func stop() async {
        guard isActive else { return }
        player.pause()
        tick()
        if let item = downloadedItem { DownloadManager.shared.savePosition(item.id, position: bookTime) }
        await reporter?.close(currentTime: bookTime)
        player.removeAllItems()
        tracksByItem = [:]
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        session = nil
        downloadedItem = nil
        localSessionId = nil
        libraryItemId = nil
        episodeId = nil
        reporter = nil
        tracks = []
        errorMessage = nil
        isPlaying = false
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Queue

    private var currentTrack: AudioTrack? {
        player.currentItem.flatMap { tracksByItem[ObjectIdentifier($0)] }
    }

    /// Queues the track containing `time` and all following ones, positioned at `time`.
    private func loadQueue(at time: Double) {
        guard let first = tracks.last(where: { $0.startOffset <= time }) ?? tracks.first else { return }
        player.removeAllItems()
        tracksByItem = [:]
        for track in tracks where track.startOffset >= first.startOffset {
            let item: AVPlayerItem
            if let downloadedItem {
                item = AVPlayerItem(url: DownloadManager.shared.localURL(downloadedItem, track))
            } else if let session, let client {
                item = AVPlayerItem(url: client.publicTrackURL(sessionId: session.id, trackIndex: track.index))
                item.preferredForwardBufferDuration = 120
            } else {
                return
            }
            tracksByItem[ObjectIdentifier(item)] = track
            player.insert(item, after: nil)
        }
        let offset = max(0, time - first.startOffset)
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        bookTime = time
    }

    // MARK: - Downloaded items

    /// Local items pause at the end of each file (`actionAtItemEnd = .pause`): a sparse file "ends" early where the
    /// download stops, which must not skip ahead to the next file.
    private func itemDidPlayToEnd(_ item: AVPlayerItem) {
        guard isLocal, let track = tracksByItem[ObjectIdentifier(item)], item === player.currentItem else { return }
        let local = item.currentTime().seconds
        if local.isFinite, local < track.duration - 2 {
            let position = track.startOffset + local
            AppLog.shared.add("reached end of downloaded part at \(Self.format(position))")
            bookTime = position
            Task { await continueAfterGap(at: position) }
        } else if player.items().count > 1 {
            player.advanceToNextItem()
            player.play()
            player.rate = rate
        } else {
            AppLog.shared.add("finished \(title)")
            bookTime = duration
            pause()
        }
    }

    /// Downloads the missing part and continues, or stops with a message when offline.
    private func continueAfterGap(at position: Double) async {
        guard let item = downloadedItem else { return }
        player.pause()
        isBuffering = true
        let available = await DownloadManager.shared.ensurePlayable(item.id, from: position)
        guard downloadedItem?.id == item.id else { return }
        isBuffering = false
        if available {
            errorMessage = nil
            loadQueue(at: position)
            _ = try? await activateAudioSession()
            player.play()
            player.rate = rate
            pausedAt = nil
            lastTick = Date()
        } else {
            let left = TimeText.duration(max(0, duration - position))
            errorMessage = "End of download, \(left) left. Connect to the internet to continue."
            bookTime = position
            pause()
        }
        updateNowPlaying()
    }

    // MARK: - Progress

    private func startTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        lastTick = Date()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1000), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Updates position and listened time; syncs when due.
    private func tick() {
        let now = Date()
        let playing = player.timeControlStatus == .playing
        if playing, let lastTick {
            let elapsed = now.timeIntervalSince(lastTick)
            if elapsed < 5 { Task { await reporter?.addListened(elapsed) } }
        }
        lastTick = now
        isPlaying = player.timeControlStatus != .paused
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        if let track = currentTrack, let item = player.currentItem {
            let local = item.currentTime().seconds
            if local.isFinite { bookTime = track.startOffset + local }
            bufferedAhead = item.loadedTimeRanges
                .map(\.timeRangeValue)
                .first { $0.start.seconds <= local + 0.5 && ($0.start + $0.duration).seconds > local }
                .map { ($0.start + $0.duration).seconds - local } ?? 0
        }

        if playing {
            let time = bookTime
            Task {
                if let outcome = await reporter?.syncIfDue(currentTime: time) { await handle(outcome) }
            }
            if let item = downloadedItem {
                if lastPositionSave.map({ now.timeIntervalSince($0) >= 15 }) ?? true {
                    lastPositionSave = now
                    DownloadManager.shared.savePosition(item.id, position: time)
                }
                if lastTopUp.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                    lastTopUp = now
                    Task { await DownloadManager.shared.topUp(item.id, position: time) }
                }
            }
        }
    }

    private func syncNow() async {
        guard let reporter else { return }
        if let item = downloadedItem { DownloadManager.shared.savePosition(item.id, position: bookTime) }
        await handle(await reporter.sync(currentTime: bookTime))
    }

    private func handle(_ outcome: PlaybackSync.Outcome) async {
        // A local session is "gone" only when the item was deleted on the server; nothing to reopen
        guard outcome == .sessionGone, session != nil else { return }
        await reopenSession()
    }

    /// The server dropped the session (restart or 36 h cleanup): open a new one and continue where we are.
    /// The public track URLs belong to the old session, so the queue is rebuilt too.
    private func reopenSession() async {
        guard let client, let libraryItemId else { return }
        AppLog.shared.add("server session gone, reopening")
        do {
            let fresh = try await client.startPlayback(libraryItemId: libraryItemId, episodeId: episodeId, model: DeviceIdentity.model)
            let position = bookTime
            let wasPlaying = isPlaying
            session = fresh
            tracks = fresh.sortedTracks
            await (reporter as? PlaybackSync)?.replaceSession(id: fresh.id)
            loadQueue(at: position)
            if wasPlaying { player.play(); player.rate = rate }
        } catch {
            AppLog.shared.add("reopen failed: \(error.localizedDescription)")
        }
    }

    /// Another device may have listened while we were paused.
    private func applyNewerServerProgress() async {
        guard let client, let libraryItemId, let pausedAt else { return }
        guard let progress = try? await client.mediaProgress(libraryItemId: libraryItemId, episodeId: episodeId) else { return }
        let serverUpdate = Date(timeIntervalSince1970: progress.lastUpdate / 1000)
        if serverUpdate > pausedAt, abs(progress.currentTime - bookTime) > 1 {
            AppLog.shared.add("applying newer server position \(Self.format(progress.currentTime))")
            seek(to: progress.currentTime)
        }
    }

    // MARK: - Audio session

    /// Long-form audio on watchOS routes to Bluetooth headphones; the system shows a route picker if none is connected.
    private func activateAudioSession() async throws -> Bool {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            audioSession.activate(options: []) { activated, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: activated)
                }
            }
        }
    }

    // MARK: - Now Playing

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: 30) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -30) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard isActive else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: bookTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let author { info[MPMediaItemPropertyArtist] = author }
        if let chapter = currentChapter?.title { info[MPMediaItemPropertyAlbumTitle] = chapter }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(libraryItemId: String, client: AbsClient) {
        let url = client.coverURL(libraryItemId: libraryItemId, width: 300)
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            guard self.libraryItemId == libraryItemId else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
