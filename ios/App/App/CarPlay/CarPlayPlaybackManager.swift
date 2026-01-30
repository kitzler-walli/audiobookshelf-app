//
//  CarPlayPlaybackManager.swift
//  App
//
//  Created for CarPlay integration.
//

import AVFoundation
import Foundation
import MediaPlayer

@available(iOS 14.0, *)
class CarPlayPlaybackManager {

    private static var nowPlayingPollTimer: Timer?

    static func playServerItem(libraryItemId: String, episodeId: String? = nil) {
        NSLog("[CARPLAY-DEBUG] playServerItem called for \(libraryItemId)")

        // If this item is already playing, just navigate to Now Playing
        if let currentSession = PlayerHandler.getPlaybackSession(),
           currentSession.libraryItemId == libraryItemId,
           (episodeId == nil || currentSession.episodeId == episodeId) {
            NSLog("[CARPLAY-DEBUG] Item already playing, pushing Now Playing")
            CarPlaySceneDelegate.shared?.pushNowPlaying()
            return
        }

        let playbackRate = PlayerSettings.main().playbackRate
        NSLog("[CARPLAY-DEBUG] Starting playback session, rate=\(playbackRate)")

        ApiClient.startPlaybackSession(libraryItemId: libraryItemId, episodeId: episodeId, forceTranscode: false) { session in
            NSLog("[CARPLAY-DEBUG] API callback received, session.id='\(session.id)' displayTitle='\(session.displayTitle ?? "NIL")' duration=\(session.duration)")

            guard !session.id.isEmpty else {
                NSLog("[CARPLAY-DEBUG] ERROR: Empty session ID!")
                return
            }

            session.serverConnectionConfigId = Store.serverConfig?.id
            session.serverAddress = Store.serverConfig?.address

            do {
                try session.save()
                NSLog("[CARPLAY-DEBUG] Session saved, calling startPlayback")
                PlayerHandler.startPlayback(sessionId: session.id, playWhenReady: true, playbackRate: playbackRate)
                scheduleNowPlayingPush()
            } catch {
                NSLog("[CARPLAY-DEBUG] ERROR saving session: \(error)")
            }
        }
    }

    static func playLocalItem(localLibraryItemId: String, episodeId: String? = nil) {
        // If this item is already playing, just navigate to Now Playing
        if let currentSession = PlayerHandler.getPlaybackSession(),
           currentSession.localLibraryItem?.id == localLibraryItemId,
           (episodeId == nil || currentSession.episodeId == episodeId) {
            CarPlaySceneDelegate.shared?.pushNowPlaying()
            return
        }

        let playbackRate = PlayerSettings.main().playbackRate

        guard let localItem = Database.shared.getLocalLibraryItem(localLibraryItemId: localLibraryItemId) else {
            AbsLogger.error(message: "CarPlay: Local item not found: \(localLibraryItemId)")
            return
        }

        let episode = localItem.getPodcastEpisode(episodeId: episodeId)
        let playbackSession = localItem.getPlaybackSession(episode: episode)

        do {
            try playbackSession.save()
            PlayerHandler.startPlayback(sessionId: playbackSession.id, playWhenReady: true, playbackRate: playbackRate)
            scheduleNowPlayingPush()
        } catch {
            AbsLogger.error(message: "CarPlay: Failed to save local playback session: \(error)")
        }
    }

    // MARK: - Now Playing Push

    /// Polls until audio is confirmed outputting, then pushes the Now Playing template.
    private static func scheduleNowPlayingPush() {
        nowPlayingPollTimer?.invalidate()
        var elapsed: TimeInterval = 0
        let interval: TimeInterval = 0.3
        let timeout: TimeInterval = 15.0

        nowPlayingPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            elapsed += interval

            // Use timeControlStatus (.playing) rather than rate > 0 to ensure
            // the AVPlayer is actually producing audio output, not just buffering.
            let isActuallyPlaying = PlayerHandler.isAudioActuallyPlaying
            let infoCenter = MPNowPlayingInfoCenter.default()
            let hasNowPlayingInfo = infoCenter.nowPlayingInfo != nil
            let playbackState = infoCenter.playbackState

            NSLog("[CARPLAY-DEBUG] Poll tick elapsed=\(String(format: "%.1f", elapsed))s isActuallyPlaying=\(isActuallyPlaying) hasInfo=\(hasNowPlayingInfo) playbackState=\(playbackState.rawValue)")

            if isActuallyPlaying && hasNowPlayingInfo {
                timer.invalidate()
                nowPlayingPollTimer = nil
                NSLog("[CARPLAY-DEBUG] Conditions met, pushing Now Playing template")
                CarPlaySceneDelegate.shared?.pushNowPlaying()
            } else if elapsed >= timeout {
                NSLog("[CARPLAY-DEBUG] Timed out waiting for playback (\(String(format: "%.1f", elapsed))s), pushing anyway")
                timer.invalidate()
                nowPlayingPollTimer = nil
                CarPlaySceneDelegate.shared?.pushNowPlaying()
            }
        }
    }
}
