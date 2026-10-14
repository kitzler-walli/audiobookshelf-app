import AVFoundation
import Foundation
import Observation

/// Thin AVPlayer wrapper that exposes the numbers the spike needs: position, buffered-ahead seconds and stall reasons.
@MainActor @Observable
final class SpikePlayer {
    private(set) var statusText = "idle"
    private(set) var bookTime: Double = 0
    private(set) var bufferedAhead: Double = 0
    private(set) var isPlaying = false
    private(set) var sourceDescription = "–"

    private let player = AVPlayer()
    private var trackStartOffset: Double = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
    }

    /// Long-form audio routes to Bluetooth headphones; watchOS shows its route picker if none is connected.
    func activateAudioSession() async throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            session.activate(options: []) { activated, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: activated)
                }
            }
        }
    }

    /// - Parameters:
    ///   - url: remote stream URL or local (sparse) file URL of one track
    ///   - bookTime: position in seconds from the start of the book
    ///   - forwardBuffer: preferred read-ahead in seconds (0 = system default)
    func load(url: URL, description: String, trackStartOffset: Double, bookTime: Double, forwardBuffer: Double) {
        removeItemObservers()
        self.trackStartOffset = trackStartOffset
        sourceDescription = description

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = forwardBuffer
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            SpikeLog.post("player: failed to play to end: \(error?.localizedDescription ?? "unknown")")
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { _ in
            SpikeLog.post("player: playback stalled")
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            SpikeLog.post("player: reached end of track")
        })
        player.replaceCurrentItem(with: item)
        seek(toBookTime: bookTime)
        SpikeLog.shared.add("player: loaded \(description) at \(Self.format(bookTime)), forward buffer \(Int(forwardBuffer)) s")
        startTimer()
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func skip(by seconds: Double) {
        seek(toBookTime: bookTime + seconds)
    }

    func seek(toBookTime time: Double) {
        let local = max(0, time - trackStartOffset)
        player.seek(to: CMTime(seconds: local, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        bookTime = time
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        timer?.invalidate()
        timer = nil
        statusText = "idle"
        isPlaying = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard let item = player.currentItem else { return }
        let local = item.currentTime().seconds
        if local.isFinite { bookTime = trackStartOffset + local }

        bufferedAhead = 0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            if start <= local + 0.5, end > local { bufferedAhead = end - local }
        }

        isPlaying = player.timeControlStatus == .playing
        switch (item.status, player.timeControlStatus) {
        case (.failed, _):
            statusText = "failed: \(item.error?.localizedDescription ?? "?")"
        case (_, .waitingToPlayAtSpecifiedRate):
            statusText = "waiting: \(player.reasonForWaitingToPlay?.rawValue ?? "?")"
        case (_, .playing):
            statusText = "playing"
        default:
            statusText = item.status == .readyToPlay ? "paused" : "loading"
        }
    }

    private func removeItemObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
