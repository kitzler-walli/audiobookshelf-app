//
//  PlayerHandler.swift
//  App
//
//  Created by Rasmus Krämer on 11.04.22.
//

import Foundation
import RealmSwift
import AVFoundation

class PlayerHandler {
    private static var player: AudioPlayer?

    public static func startPlayback(sessionId: String, playWhenReady: Bool, playbackRate: Float) {
        NSLog("[CARPLAY-DEBUG] PlayerHandler.startPlayback sessionId=\(sessionId) playWhenReady=\(playWhenReady) rate=\(playbackRate)")
        guard let session = Database.shared.getPlaybackSession(id: sessionId) else {
            NSLog("[CARPLAY-DEBUG] ERROR: Could not load session from database!")
            return
        }
        NSLog("[CARPLAY-DEBUG] Session loaded: title='\(session.displayTitle ?? "NIL")' author='\(session.displayAuthor ?? "NIL")' duration=\(session.duration) tracks=\(session.audioTracks.count)")

        // Clean up the existing player (but DON'T deactivate audio session if we're immediately starting a new one)
        resetPlayer(keepAudioSessionActive: playWhenReady)

        // Cleanup and sync old sessions
        cleanupOldSessions(currentSessionId: sessionId)

        // Ensure audio session is active BEFORE creating the player
        if playWhenReady {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                AbsLogger.info(message: "PlayerHandler: Audio session activated before playback")
            } catch {
                AbsLogger.error(message: "PlayerHandler: Failed to activate audio session", error: error)
            }
        }

        player = AudioPlayer(sessionId: sessionId, playWhenReady: playWhenReady, playbackRate: playbackRate)

        // Set now-playing metadata after the player is created
        NowPlayingInfo.shared.setSessionMetadata(metadata: NowPlayingMetadata(id: session.id, itemId: session.libraryItemId!, title: session.displayTitle ?? "Unknown title", author: session.displayAuthor, series: nil, isLocal: session.isLocal, playbackRate: playbackRate, duration: session.duration, currentTime: session.currentTime))
    }

    public static func stopPlayback(currentSessionId: String? = nil) {
        // Pause playback first, so we can sync our current progress
        player?.pause()
        resetPlayer()
        cleanupOldSessions(currentSessionId: currentSessionId)
        NowPlayingInfo.shared.reset()
    }

    public static var paused: Bool {
        get {
            guard let player = player else { return true }
            return player.rateManager.rate == 0.0
        }
        set(paused) {
            if paused {
                self.player?.pause()
            } else {
                self.player?.play(allowSeekBack: true)
            }
        }
    }

    /// True when the AVPlayer is actively producing audio output.
    /// More reliable than checking rate > 0, which can be true while still buffering.
    public static var isAudioActuallyPlaying: Bool {
        guard let player = player else { return false }
        return player.audioPlayer.timeControlStatus == .playing
    }

    public static func getCurrentTime() -> Double? {
        self.player?.getCurrentTime()
    }

    public static func getPlayWhenReady() -> Bool {
        self.player?.playWhenReady ?? false
    }

    public static func setPlaybackSpeed(speed: Float) {
        self.player?.setPlaybackRate(speed)
    }

    public static func setChapterTrack() {
        self.player?.setChapterTrack()
    }

    public static func getSleepTimeRemaining() -> Double? {
        return self.player?.getSleepTimeRemaining()
    }

    public static func setSleepTime(secondsUntilSleep: Double) {
        self.player?.setSleepTimer(secondsUntilSleep: secondsUntilSleep)
    }

    public static func setChapterSleepTime(stopAt: Double) {
        self.player?.setChapterSleepTimer(stopAt: stopAt)
    }

    public static func increaseSleepTime(increaseSeconds: Double) {
        self.player?.increaseSleepTime(extraTimeInSeconds: increaseSeconds)
    }

    public static func decreaseSleepTime(decreaseSeconds: Double) {
        self.player?.decreaseSleepTime(removeTimeInSeconds: decreaseSeconds)
    }

    public static func cancelSleepTime() {
        self.player?.removeSleepTimer()
    }

    public static func getPlayMethod() -> Int? {
        self.player?.getPlayMethod()
    }

    public static func getPlaybackSession() -> PlaybackSession? {
        guard let player = player else { return nil }

        return player.getPlaybackSession()
    }

    public static func seekForward(amount: Double) {
        guard let player = player else { return }
        guard player.isInitialized() else { return }
        guard let currentTime = player.getCurrentTime() else { return }

        let destinationTime = currentTime + amount
        player.seek(destinationTime, from: "handler")
    }

    public static func seekBackward(amount: Double) {
        guard let player = player else { return }
        guard player.isInitialized() else { return }
        guard let currentTime = player.getCurrentTime() else { return }

        let destinationTime = currentTime - amount
        player.seek(destinationTime, from: "handler")
    }

    public static func seek(amount: Double) {
        guard let player = player else { return }
        guard player.isInitialized() else { return }

        player.seek(amount, from: "handler")
    }

    public static func getMetdata() -> PlaybackMetadata? {
        guard let player = player else { return nil }
        guard player.isInitialized() else { return nil }

        return PlaybackMetadata(
            duration: player.getDuration() ?? 0,
            currentTime: player.getCurrentTime() ?? 0,
            playerState: player.getPlayerState()
        )
    }

    public static func updateRemoteTransportControls() {
        self.player?.setupRemoteTransportControls()
    }

    // MARK: - Helper logic

    private static func cleanupOldSessions(currentSessionId: String?) {
        do {
            let realm = try Realm()
            let oldSessions = realm.objects(PlaybackSession.self) .where({
                $0.isActiveSession == true && $0.serverConnectionConfigId == Store.serverConfig?.id
            })
            try realm.write {
                for s in oldSessions {
                    if s.id != currentSessionId {
                        s.isActiveSession = false
                    }
                }
            }
        } catch {
            debugPrint("Failed to cleanup sessions")
            debugPrint(error)
        }
    }

    private static func resetPlayer(keepAudioSessionActive: Bool = false) {
        if let player = player {
            player.destroy(keepAudioSessionActive: keepAudioSessionActive)
        }
        player = nil
    }
}
