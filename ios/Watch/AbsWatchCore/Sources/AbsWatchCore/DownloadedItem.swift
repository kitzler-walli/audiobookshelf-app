import Foundation

/// How much of an item is kept on the watch.
public enum DownloadScope: Codable, Sendable, Hashable {
    /// Every byte of every track
    case full
    /// A rolling window of this many seconds from the listening position, topped up while listening
    case ahead(seconds: Double)
}

/// A book or podcast episode with (some of) its audio on the watch. Everything needed to play it offline is stored
/// here, so it can be listened to without reaching the server.
public struct DownloadedItem: Codable, Sendable, Identifiable, Hashable {
    public let libraryItemId: String
    public let episodeId: String?
    public let isPodcast: Bool
    public let title: String
    public let author: String?
    public let duration: Double
    public let chapters: [Chapter]
    public let tracks: [AudioTrack]
    public var scope: DownloadScope
    /// Start of the planned window for `.ahead`; moves along with the listening position
    public var windowStart: Double
    public let createdAt: Date
    /// Last position played on the watch, used when starting offline
    public var position: Double?
    public var positionUpdatedAt: Date?

    public init(libraryItemId: String, episodeId: String?, isPodcast: Bool, title: String, author: String?, duration: Double,
                chapters: [Chapter], tracks: [AudioTrack], scope: DownloadScope, windowStart: Double, createdAt: Date = Date()) {
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.isPodcast = isPodcast
        self.title = title
        self.author = author
        self.duration = duration
        self.chapters = chapters
        self.tracks = tracks
        self.scope = scope
        self.windowStart = windowStart
        self.createdAt = createdAt
    }

    public static func key(libraryItemId: String, episodeId: String?) -> String {
        episodeId.map { "\(libraryItemId)-\($0)" } ?? libraryItemId
    }

    public var id: String { Self.key(libraryItemId: libraryItemId, episodeId: episodeId) }

    /// Track indices are 1-based and may skip excluded files; order by start offset instead.
    public var sortedTracks: [AudioTrack] { tracks.sorted { $0.startOffset < $1.startOffset } }

    public var totalBytes: Int64 { tracks.reduce(0) { $0 + ($1.metadata?.size ?? 0) } }

    public func track(at time: Double) -> AudioTrack? {
        let tracks = sortedTracks
        return tracks.last { $0.startOffset <= time } ?? tracks.first
    }

    /// File name of a track inside the item's download folder.
    public func fileName(for track: AudioTrack) -> String {
        "track-\(track.index).\(track.ext.isEmpty ? "bin" : track.ext)"
    }

    /// Byte ranges that should be on disk.
    public func plan() -> [WindowPlanner.TrackPlan] {
        switch scope {
        case .full:
            return sortedTracks.compactMap { track in
                guard let size = track.metadata?.size, size > 0 else { return nil }
                return WindowPlanner.TrackPlan(trackIndex: track.index, ranges: [0..<size])
            }
        case .ahead(let seconds):
            return WindowPlanner.plan(tracks: sortedTracks.map(\.plannerInfo), start: windowStart, duration: seconds)
        }
    }

    /// Book time up to which playback can run from `time` without reaching bytes that are not on disk.
    /// Returns `time` itself when nothing is playable there.
    ///
    /// Inside a partly downloaded track the byte position is estimated from the average bitrate, so the end is pulled
    /// in by a safety margin (an m4b's index before the audio shifts the real position back by its size). Container
    /// headers must be present (see `WindowPlanner`). Should playback still run into missing bytes, the player fetches them.
    public func playableEnd(from time: Double, present: (AudioTrack) -> ByteRangeIndex) -> Double {
        var position = time
        for track in sortedTracks where track.startOffset + track.duration > position {
            guard let size = track.metadata?.size, size > 0, track.duration > 0 else { return position }
            let ranges = present(track)
            let trackEnd = track.startOffset + track.duration
            if ranges.contains(0..<size) {
                position = trackEnd
                continue
            }

            let info = track.plannerInfo
            guard ranges.contains(0..<min(WindowPlanner.headerBytes, size)),
                  !info.isMP4Family || ranges.contains(max(0, size - WindowPlanner.headerBytes)..<size) else { return position }

            let bytesPerSecond = Double(size) / track.duration
            let byte = Int64(max(0, position - track.startOffset) * bytesPerSecond)
            let safety = max(WindowPlanner.minimumMarginBytes, size / 200)
            guard let range = ranges.ranges.first(where: { $0.contains(byte) }),
                  range.lowerBound == 0 || byte - range.lowerBound >= WindowPlanner.minimumMarginBytes else { return position }
            let end = range.upperBound == size ? size : range.upperBound - safety
            guard end > byte else { return position }
            return min(trackEnd, track.startOffset + Double(end) / bytesPerSecond)
        }
        return position
    }

    public static func plannedBytes(_ plans: [WindowPlanner.TrackPlan]) -> Int64 {
        plans.reduce(0) { $0 + $1.ranges.reduce(0) { $0 + Int64($1.count) } }
    }

    /// Bytes of `plans` that are on disk.
    public static func presentBytes(_ plans: [WindowPlanner.TrackPlan], present: (Int) -> ByteRangeIndex) -> Int64 {
        plans.reduce(0) { total, plan in
            let index = present(plan.trackIndex)
            return total + plan.ranges.reduce(0) { sum, range in
                sum + Int64(range.count) - index.missing(in: range).reduce(0) { $0 + Int64($1.count) }
            }
        }
    }
}

/// Download records on disk: one folder per item with `item.json`, the track files and the cover.
public struct DownloadStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(for key: String) -> URL {
        root.appending(path: key, directoryHint: .isDirectory)
    }

    public func trackURL(_ item: DownloadedItem, _ track: AudioTrack) -> URL {
        directory(for: item.id).appending(path: item.fileName(for: track))
    }

    public func coverURL(for key: String) -> URL {
        directory(for: key).appending(path: "cover.jpg")
    }

    public func save(_ item: DownloadedItem) throws {
        var directory = directory(for: item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(item).write(to: directory.appending(path: "item.json"), options: .atomic)
    }

    public func loadAll() -> [DownloadedItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "item.json")) else { return nil }
            return try? decoder.decode(DownloadedItem.self, from: data)
        }
    }

    public func delete(key: String) {
        try? FileManager.default.removeItem(at: directory(for: key))
    }

    /// Bytes allocated on disk for an item (holes of sparse files excluded).
    public func allocatedBytes(for key: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory(for: key), includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
