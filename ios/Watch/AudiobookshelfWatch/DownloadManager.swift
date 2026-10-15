import AbsWatchCore
import Foundation
import Observation
import UIKit

/// The items on the watch and their downloads.
///
/// Whole books are fetched once; "ahead" downloads keep a window of the next hours from the listening position and
/// are topped up while listening. While the app is in front or playing, the fast default URLSession is used;
/// otherwise the jobs move to the background session so they continue while the app is suspended.
@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()
    static let root = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    /// Keep this much free so the watch stays usable.
    static let reserveBytes: Int64 = 500 << 20

    struct Status {
        var plannedBytes: Int64 = 0
        var presentBytes: Int64 = 0
        var isActive = false
        var error: String?
        /// Smoothed download speed while active
        var bytesPerSecond: Double?

        var fraction: Double { plannedBytes > 0 ? min(1, Double(presentBytes) / Double(plannedBytes)) : 0 }
        var remainingSeconds: Double? {
            guard let bytesPerSecond, bytesPerSecond >= 1024 else { return nil }
            return Double(max(0, plannedBytes - presentBytes)) / bytesPerSecond
        }
        var isComplete: Bool { plannedBytes > 0 && presentBytes >= plannedBytes }
    }

    enum DownloadError: LocalizedError {
        case noAudio
        case notEnoughSpace(needed: Int64)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This item has no audio files"
            case .notEnoughSpace(let needed): return "Not enough space on the watch (needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)))"
            }
        }
    }

    private(set) var items: [DownloadedItem] = []
    private(set) var status: [String: Status] = [:]
    let store = DownloadStore(root: DownloadManager.root)
    let downloader = TrackDownloader(root: DownloadManager.root)

    var allowsCellular: Bool {
        get { UserDefaults.standard.object(forKey: "downloadsOverCellular") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "downloadsOverCellular") }
    }

    private var appIsActive = true
    private var usesBackground = false
    private var pendingRefresh: Set<String> = []
    private var speedMeter: Task<Void, Never>?
    private var speedSamples: [String: (bytes: Int64, at: ContinuousClock.Instant)] = [:]

    private init() {
        downloader.makeRequest = { job, token in
            var request = URLRequest(url: URL(string: job.contentUrl)!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("bytes=\(job.lower)-\(job.upper - 1)", forHTTPHeaderField: "Range")
            return request
        }
        downloader.refreshToken = { failed in
            guard let tokens = await MainActor.run(body: { AppModel.shared.tokens }) else { return nil }
            return try? await tokens.refresh(after: failed)
        }
        downloader.onChange = { key, error in
            Task { @MainActor in DownloadManager.shared.chunkChanged(key: key, error: error) }
        }
        items = store.loadAll().sorted { $0.createdAt > $1.createdAt }
        for item in items { refreshStatus(item.id) }
    }

    func item(libraryItemId: String, episodeId: String?) -> DownloadedItem? {
        let key = DownloadedItem.key(libraryItemId: libraryItemId, episodeId: episodeId)
        return items.first { $0.id == key }
    }

    // MARK: - Starting and removing

    /// Starts downloading a book, or one podcast episode.
    func download(_ detail: LibraryItemDetail, episode: Episode? = nil, scope: DownloadScope) async throws {
        let tracks = episode.map { $0.audioTrack.map { [$0] } ?? [] } ?? (detail.media.tracks ?? [])
        guard !tracks.isEmpty, tracks.allSatisfy({ ($0.metadata?.size ?? 0) > 0 }) else { throw DownloadError.noAudio }

        var position = 0.0
        var positionDate: Date?
        if episode == nil, let progress = detail.userMediaProgress {
            position = progress.isFinished ? 0 : progress.currentTime
            positionDate = Date(timeIntervalSince1970: progress.lastUpdate / 1000)
        }
        var item = DownloadedItem(
            libraryItemId: detail.id, episodeId: episode?.id, isPodcast: detail.isPodcast,
            title: episode?.title ?? detail.title,
            author: episode != nil ? detail.title : detail.authorName,
            duration: episode?.duration ?? detail.media.duration ?? tracks.reduce(0) { $0 + $1.duration },
            chapters: episode == nil ? (detail.media.chapters ?? []) : [],
            tracks: tracks, scope: scope, windowStart: max(0, position - 60))
        item.position = position
        item.positionUpdatedAt = positionDate

        let needed = DownloadedItem.plannedBytes(item.plan())
        if let free = freeBytes, needed > free - Self.reserveBytes {
            throw DownloadError.notEnoughSpace(needed: needed)
        }

        try store.save(item)
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        AppLog.shared.add("download \(item.title): \(Self.describe(scope)), \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))")
        saveCover(for: item)
        await enqueue(item)
    }

    func remove(_ key: String) {
        downloader.cancel(key: key)
        store.delete(key: key)
        items.removeAll { $0.id == key }
        status[key] = nil
        if let item = PlayerController.shared.downloadedItem, item.id == key {
            Task { await PlayerController.shared.stop() }
        }
    }

    func removeAll() {
        downloader.cancel()
        for item in items { store.delete(key: item.id) }
        items = []
        status = [:]
    }

    // MARK: - Keeping downloads going

    /// Queues whatever is missing of every item, e.g. at launch or when the network is back.
    func resumeAll() async {
        for item in items { await enqueue(item) }
    }

    /// Moves the "ahead" window to the listening position and fetches what is missing.
    func topUp(_ key: String, position: Double) async {
        guard var item = items.first(where: { $0.id == key }), case .ahead = item.scope else { return }
        let start = max(0, position - 60)
        // Re-plan every few minutes of listening, not on every tick
        guard abs(start - item.windowStart) > 300 || !(status[key]?.isComplete ?? false) else { return }
        item.windowStart = start
        update(item)
        await enqueue(item)
    }

    /// Fetches the next minutes from `time` with priority (the player ran into missing bytes, or seeked there).
    /// Returns true once playback can continue, false when the download failed or took too long.
    func ensurePlayable(_ key: String, from time: Double, seconds: Double = 600, timeout: Duration = .seconds(60)) async -> Bool {
        guard let item = items.first(where: { $0.id == key }) else { return false }
        let goal = min(item.duration, time + 60)
        if playableEnd(item, from: time) >= goal { return true }

        let plans = WindowPlanner.plan(tracks: item.sortedTracks.map(\.plannerInfo), start: time, duration: seconds)
        guard await enqueue(item, plans: plans, urgent: true) else { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if playableEnd(item, from: time) >= goal { return true }
            if !downloader.isActive(key: key) { return playableEnd(item, from: time) >= goal }
        }
        return false
    }

    /// Book time up to which the item can play from `time` with what is on disk.
    func playableEnd(_ item: DownloadedItem, from time: Double) -> Double {
        item.playableEnd(from: time) { presentRanges(item, $0) }
    }

    func localURL(_ item: DownloadedItem, _ track: AudioTrack) -> URL {
        store.trackURL(item, track)
    }

    /// Remembers the listening position so the item can start offline where it was left.
    func savePosition(_ key: String, position: Double) {
        guard var item = items.first(where: { $0.id == key }) else { return }
        item.position = position
        item.positionUpdatedAt = Date()
        update(item)
    }

    /// Called when the app goes to the background or comes back.
    func appStateChanged(isActive: Bool) {
        appIsActive = isActive
        chooseSession()
    }

    /// A playing app keeps running in the background, so the fast session can be used while it plays.
    func playbackChanged() {
        chooseSession()
    }

    private func chooseSession() {
        let player = PlayerController.shared
        // While the player waits for a missing part, that download must stay fast
        let wantsBackground = !appIsActive && !player.isPlaying && !player.isBuffering
        guard wantsBackground != usesBackground else { return }
        usesBackground = wantsBackground
        let moved = downloader.takeJobs(inBackground: !wantsBackground)
        guard !moved.isEmpty else { return }
        AppLog.shared.add("moving \(moved.count) download(s) to the \(wantsBackground ? "background" : "foreground") session")
        Task {
            for key in Set(moved.map(\.key)) {
                if let item = items.first(where: { $0.id == key }) { await enqueue(item) }
            }
        }
    }

    // MARK: - Space

    var freeBytes: Int64? {
        let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    func allocatedBytes(_ key: String) -> Int64 {
        store.allocatedBytes(for: key)
    }

    static func describe(_ scope: DownloadScope) -> String {
        switch scope {
        case .full: return "whole book"
        case .ahead(let seconds): return "next \(TimeText.duration(seconds))"
        }
    }

    // MARK: - Internals

    @discardableResult
    private func enqueue(_ item: DownloadedItem, plans: [WindowPlanner.TrackPlan]? = nil, urgent: Bool = false) async -> Bool {
        guard let tokens = AppModel.shared.tokens, let token = try? await tokens.accessToken() else { return false }
        let plans = plans ?? item.plan()
        let inBackground = urgent ? false : usesBackground
        var queued: Int64 = 0
        status[item.id, default: Status()].error = nil
        for plan in plans {
            guard let track = item.tracks.first(where: { $0.index == plan.trackIndex }), let size = track.metadata?.size else { continue }
            do {
                queued += try downloader.enqueue(
                    key: item.id, path: "\(item.id)/\(item.fileName(for: track))",
                    contentUrl: tokens.serverAddress.appending(path: track.contentUrl).absoluteString,
                    contentLength: size, ranges: plan.ranges, token: token,
                    inBackground: inBackground, urgent: urgent, cellular: allowsCellular)
            } catch {
                status[item.id, default: Status()].error = error.localizedDescription
                AppLog.shared.add("download \(item.title) failed: \(error.localizedDescription)")
                return false
            }
        }
        if queued > 0 {
            AppLog.shared.add("queued \(ByteCountFormatter.string(fromByteCount: queued, countStyle: .file)) of \(item.title)\(inBackground ? " (background)" : "")")
        }
        refreshStatus(item.id)
        return true
    }

    private func chunkChanged(key: String, error: String?) {
        if let error {
            status[key, default: Status()].error = error
            AppLog.shared.add("download error: \(error)")
        }
        // Many chunks finish close together; recompute once per run loop turn
        guard pendingRefresh.insert(key).inserted else { return }
        Task { @MainActor in
            pendingRefresh.remove(key)
            refreshStatus(key)
        }
    }

    private func refreshStatus(_ key: String) {
        guard let item = items.first(where: { $0.id == key }) else { return }
        let plans = item.plan()
        var current = status[key] ?? Status()
        let wasComplete = current.isComplete
        current.plannedBytes = DownloadedItem.plannedBytes(plans)
        current.presentBytes = DownloadedItem.presentBytes(plans) { index in
            item.tracks.first { $0.index == index }.map { presentRanges(item, $0) } ?? ByteRangeIndex()
        }
        current.isActive = downloader.isActive(key: key)
        if current.isComplete { current.error = nil }
        if !current.isActive { current.bytesPerSecond = nil }
        status[key] = current
        if current.isActive { startSpeedMeter() }
        if current.isComplete, !wasComplete, case .full = item.scope {
            AppLog.shared.add("downloaded \(item.title)")
        }
    }

    /// Samples the received bytes every second while anything downloads.
    private func startSpeedMeter() {
        guard speedMeter == nil else { return }
        speedMeter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.sampleSpeeds() else { break }
            }
            self?.speedMeter = nil
        }
    }

    /// Returns false when nothing is downloading any more.
    private func sampleSpeeds() -> Bool {
        let now = ContinuousClock.now
        var anyActive = false
        for item in items {
            let key = item.id
            guard downloader.isActive(key: key) else {
                speedSamples[key] = nil
                if status[key]?.bytesPerSecond != nil { status[key]?.bytesPerSecond = nil }
                continue
            }
            anyActive = true
            let bytes = downloader.receivedBytes(key: key)
            if let last = speedSamples[key] {
                let seconds = Double((now - last.at).components.seconds) + Double((now - last.at).components.attoseconds) / 1e18
                let rate = Double(bytes - last.bytes) / max(seconds, 0.1)
                let previous = status[key]?.bytesPerSecond
                // Smooth over a few seconds; chunks arrive in bursts
                status[key, default: Status()].bytesPerSecond = previous.map { $0 * 0.7 + rate * 0.3 } ?? rate
            }
            speedSamples[key] = (bytes, now)
        }
        return anyActive
    }

    private func presentRanges(_ item: DownloadedItem, _ track: AudioTrack) -> ByteRangeIndex {
        guard let size = track.metadata?.size,
              let file = try? downloader.file(path: "\(item.id)/\(item.fileName(for: track))", contentLength: size) else { return ByteRangeIndex() }
        return file.presentRanges
    }

    private func update(_ item: DownloadedItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        try? store.save(item)
    }

    private func saveCover(for item: DownloadedItem) {
        guard let client = AppModel.shared.client else { return }
        let url = client.coverURL(libraryItemId: item.libraryItemId, width: 300)
        let destination = store.coverURL(for: item.id)
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }
}
