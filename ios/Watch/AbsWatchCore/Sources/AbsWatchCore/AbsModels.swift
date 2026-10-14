import Foundation

// MARK: - Catalog

public struct LibrariesResponse: Decodable, Sendable {
    public let libraries: [Library]
}

public struct Library: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let mediaType: String

    public var isPodcast: Bool { mediaType == "podcast" }
}

public struct LibraryItemsPage: Decodable, Sendable {
    public let results: [LibraryItemSummary]
    public let total: Int?
}

public struct ItemsInProgressResponse: Decodable, Sendable {
    public let libraryItems: [LibraryItemSummary]
}

/// Minified library item as returned by item lists and items-in-progress.
public struct LibraryItemSummary: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let mediaType: String?
    public let media: Media?
    /// Only for items-in-progress of podcasts: the episode last listened to.
    public let recentEpisode: Episode?

    public struct Media: Decodable, Sendable, Hashable {
        public let metadata: Metadata?
        /// Books only; podcasts have no duration in the minified form.
        public let duration: Double?
    }

    public struct Metadata: Decodable, Sendable, Hashable {
        public let title: String?
        /// Books
        public let authorName: String?
        /// Podcasts
        public let author: String?
    }

    public var isPodcast: Bool { mediaType == "podcast" }
    public var title: String { recentEpisode?.title ?? media?.metadata?.title ?? "Unknown" }
    public var authorName: String? {
        if isPodcast, recentEpisode != nil { return media?.metadata?.title }
        return Self.nonEmpty(media?.metadata?.authorName) ?? Self.nonEmpty(media?.metadata?.author)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public struct Episode: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String?
    public let duration: Double?
    public let publishedAt: Double?
}

public struct Chapter: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String
}

/// Expanded library item (`GET /api/items/:id?expanded=1&include=progress`).
public struct LibraryItemDetail: Decodable, Sendable, Identifiable {
    public let id: String
    public let mediaType: String?
    public let media: Media
    public let userMediaProgress: MediaProgress?

    public struct Media: Decodable, Sendable {
        public let metadata: Metadata
        public let duration: Double?
        public let chapters: [Chapter]?
        public let episodes: [Episode]?
    }

    public struct Metadata: Decodable, Sendable {
        public let title: String?
        public let subtitle: String?
        public let authorName: String?
        public let author: String?
        public let narratorName: String?
        public let seriesName: String?
        public let descriptionPlain: String?
    }

    public var isPodcast: Bool { mediaType == "podcast" }
    public var title: String { media.metadata.title ?? "Unknown" }
    public var authorName: String? { LibraryItemSummary.nonEmpty(media.metadata.authorName) ?? LibraryItemSummary.nonEmpty(media.metadata.author) }
    public var narratorName: String? { LibraryItemSummary.nonEmpty(media.metadata.narratorName) }
    public var seriesName: String? { LibraryItemSummary.nonEmpty(media.metadata.seriesName) }
    /// Newest first
    public var episodes: [Episode] { (media.episodes ?? []).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) } }
}

public struct MediaProgress: Decodable, Sendable, Hashable {
    public let libraryItemId: String?
    public let episodeId: String?
    public let duration: Double
    public let progress: Double
    public let currentTime: Double
    public let isFinished: Bool
    /// Epoch milliseconds
    public let lastUpdate: Double

    public var remaining: Double { max(0, duration - currentTime) }
}

struct MeResponse: Decodable {
    let mediaProgress: [MediaProgress]
}

// MARK: - Playback

public struct PlaybackSession: Decodable, Sendable {
    public let id: String
    public let libraryItemId: String?
    public let episodeId: String?
    public let displayTitle: String?
    public let displayAuthor: String?
    public let currentTime: Double
    public let duration: Double
    public let playMethod: Int
    public let chapters: [Chapter]?
    public let audioTracks: [AudioTrack]

    /// Track indices are 1-based and may skip excluded files; order by start offset instead.
    public var sortedTracks: [AudioTrack] { audioTracks.sorted { $0.startOffset < $1.startOffset } }

    /// Track playing at `time` (seconds from the start of the book).
    public func track(at time: Double) -> AudioTrack? {
        let tracks = sortedTracks
        return tracks.last { $0.startOffset <= time } ?? tracks.first
    }
}

public struct AudioTrack: Decodable, Sendable, Hashable {
    public let index: Int
    public let startOffset: Double
    public let duration: Double
    public let title: String?
    public let contentUrl: String
    public let mimeType: String?
    public let metadata: FileMetadata?

    public struct FileMetadata: Decodable, Sendable, Hashable {
        public let filename: String?
        public let ext: String?
        public let size: Int64?
    }

    public var ext: String {
        (metadata?.ext ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public var plannerInfo: WindowPlanner.TrackInfo {
        WindowPlanner.TrackInfo(index: index, startOffset: startOffset, duration: duration, size: metadata?.size ?? 0, ext: ext)
    }
}

/// Server play method values (see server/utils/constants.js).
public enum PlayMethod {
    public static let directPlay = 0
    public static let directStream = 1
    public static let transcode = 2
    public static let local = 3
}
