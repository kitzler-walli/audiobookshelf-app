//
//  NowPlaying.swift
//  App
//
//  Created by Rasmus Krämer on 22.03.22.
//

import Foundation
import MediaPlayer
import AVFoundation

struct NowPlayingMetadata {
    var id: String
    var itemId: String
    var title: String
    var author: String?
    var series: String?
    var isLocal: Bool
    var playbackRate: Float
    var duration: Double
    var currentTime: Double
    var chapterTitle: String?

    var coverUrl: URL? {
        if self.isLocal {
            guard let item = Database.shared.getLocalLibraryItem(byServerLibraryItemId: self.itemId) else { return nil }
            return item.coverUrl
        } else {
            guard let config = Store.serverConfig else { return nil }

            // As of v2.17.0 token is not needed with cover image requests
            let coverUrlString: String
            if Store.isServerVersionGreaterThanOrEqualTo("2.17.0") {
                coverUrlString = "\(config.address)/api/items/\(itemId)/cover"
            } else {
                coverUrlString = "\(config.address)/api/items/\(itemId)/cover?token=\(config.token)"
            }

            return URL(string: coverUrlString)
        }
    }
}

class NowPlayingInfo {
    static var shared = {
        return NowPlayingInfo()
    }()

    // All access to these properties must happen on the main thread
    private var nowPlayingInfo: [String: Any]
    private var storedTitle: String?
    private var storedAuthor: String?
    // When an MPNowPlayingSession is active, this points to the session's info center.
    // We always ALSO write to the default info center as a fallback.
    private var sessionInfoCenter: MPNowPlayingInfoCenter?

    private init() {
        self.nowPlayingInfo = [:]
    }

    /// Set the MPNowPlayingSession's info center. Metadata will be written to BOTH
    /// this center and MPNowPlayingInfoCenter.default().
    public func setInfoCenter(_ center: MPNowPlayingInfoCenter) {
        self.sessionInfoCenter = center
        NSLog("[CARPLAY-DEBUG] NowPlayingInfo: sessionInfoCenter set (isDefault=\(center === MPNowPlayingInfoCenter.default()))")
    }

    public func setSessionMetadata(metadata: NowPlayingMetadata) {
        NSLog("[CARPLAY-DEBUG] setSessionMetadata called: title='\(metadata.title)' author='\(metadata.author ?? "NIL")' rate=\(metadata.playbackRate) duration=\(metadata.duration)")
        let coverUrl = metadata.coverUrl

        // All dictionary mutations on the main thread to prevent races with update()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                NSLog("[CARPLAY-DEBUG] ERROR: self is nil in setSessionMetadata main block!")
                return
            }
            NSLog("[CARPLAY-DEBUG] Main queue block executing for setSessionMetadata")

            self.storedTitle = metadata.title
            self.storedAuthor = metadata.author

            // Playback rate and duration — set immediately so CarPlay shows
            // the correct rate button text and progress bar from the first push
            self.nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = metadata.playbackRate
            self.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = metadata.playbackRate
            self.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = metadata.duration
            self.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = metadata.currentTime

            // Clear artwork for a new item
            if self.shouldFetchCover(id: metadata.id) {
                self.nowPlayingInfo[MPMediaItemPropertyArtwork] = nil
            }

            // Identification
            self.nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] = metadata.id
            self.nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false
            self.nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

            // Title / Author
            self.nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title
            self.nowPlayingInfo[MPMediaItemPropertyArtist] = metadata.author ?? "unknown"
            self.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = metadata.title

            // Push to system (both session info center and default)
            self.pushInfoToSystem()
            self.setPlaybackState(.playing)

            NSLog("[CARPLAY-DEBUG] MPNowPlayingInfoCenter pushed with \(self.nowPlayingInfo.count) keys")
            NSLog("[CARPLAY-DEBUG]   title=\(self.nowPlayingInfo[MPMediaItemPropertyTitle] ?? "MISSING")")
            NSLog("[CARPLAY-DEBUG]   artist=\(self.nowPlayingInfo[MPMediaItemPropertyArtist] ?? "MISSING")")
            NSLog("[CARPLAY-DEBUG]   rate=\(self.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] ?? "MISSING")")
            NSLog("[CARPLAY-DEBUG]   defaultRate=\(self.nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] ?? "MISSING")")
            NSLog("[CARPLAY-DEBUG]   duration=\(self.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] ?? "MISSING")")
            let sessionState = self.sessionInfoCenter.map { String($0.playbackState.rawValue) } ?? "nil"
            NSLog("[CARPLAY-DEBUG]   playbackState(default)=\(MPNowPlayingInfoCenter.default().playbackState.rawValue) session=\(sessionState)")
            AbsLogger.info(message: "NowPlayingInfo: Metadata pushed with \(self.nowPlayingInfo.count) keys, rate=\(metadata.playbackRate), duration=\(metadata.duration)")
        }

        // Load artwork asynchronously
        guard let url = coverUrl else {
            AbsLogger.info(message: "NowPlayingInfo: No cover URL available")
            return
        }

        ApiClient.getData(from: url) { [weak self] image in
            guard let self = self, let downloadedImage = image else {
                AbsLogger.error(message: "NowPlayingInfo: Failed to load cover art from \(url)")
                return
            }

            let artwork = MPMediaItemArtwork.init(boundsSize: downloadedImage.size, requestHandler: { _ -> UIImage in
                return downloadedImage
            })

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                self.pushInfoToSystem()
                AbsLogger.info(message: "NowPlayingInfo: Cover art loaded and updated")
            }
        }
    }

    public func update(duration: Double, currentTime: Double, rate: Float, defaultRate: Float, chapterName: String? = nil, chapterNumber: Int? = nil, chapterCount: Int? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            self.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            self.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = rate
            self.nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = defaultRate

            self.setPlaybackState(rate > 0 ? .playing : .paused)

            if let chapterNumber = chapterNumber, let chapterCount = chapterCount {
                self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = chapterNumber
                self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterCount] = chapterCount
            } else {
                self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = nil
                self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterCount] = nil
            }

            // Always keep the book title, never use chapter title
            if let bookTitle = self.storedTitle {
                self.nowPlayingInfo[MPMediaItemPropertyTitle] = bookTitle
            } else if let albumTitle = self.nowPlayingInfo[MPMediaItemPropertyAlbumTitle] {
                self.nowPlayingInfo[MPMediaItemPropertyTitle] = albumTitle
            }

            // Show chapter name in the artist/subtitle field: "Author · Chapter Name"
            if let chapterName = chapterName, !chapterName.isEmpty {
                if let author = self.storedAuthor, !author.isEmpty {
                    self.nowPlayingInfo[MPMediaItemPropertyArtist] = "\(author) · \(chapterName)"
                } else {
                    self.nowPlayingInfo[MPMediaItemPropertyArtist] = chapterName
                }
            } else if let author = self.storedAuthor {
                self.nowPlayingInfo[MPMediaItemPropertyArtist] = author
            }

            self.pushInfoToSystem()
        }
    }

    public func reset() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.storedTitle = nil
            self.storedAuthor = nil
            self.nowPlayingInfo = [:]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            if let sessionCenter = self.sessionInfoCenter {
                sessionCenter.nowPlayingInfo = nil
                sessionCenter.playbackState = .stopped
            }
            self.sessionInfoCenter = nil
        }
    }

    /// Write nowPlayingInfo to all active info centers (session + default).
    private func pushInfoToSystem() {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        defaultCenter.nowPlayingInfo = self.nowPlayingInfo
        if let sessionCenter = self.sessionInfoCenter, sessionCenter !== defaultCenter {
            sessionCenter.nowPlayingInfo = self.nowPlayingInfo
        }
    }

    /// Set playbackState on all active info centers.
    private func setPlaybackState(_ state: MPNowPlayingPlaybackState) {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        defaultCenter.playbackState = state
        if let sessionCenter = self.sessionInfoCenter, sessionCenter !== defaultCenter {
            sessionCenter.playbackState = state
        }
    }

    private func shouldFetchCover(id: String) -> Bool {
        nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String != id || nowPlayingInfo[MPMediaItemPropertyArtwork] == nil
    }
}
