import Foundation

/// Works out which byte ranges of which tracks are needed to play a time window offline.
///
/// Byte offsets inside a track are estimated from the track's average bitrate. To keep that estimate safe the window
/// is widened by a margin, and container headers are always included: the start of every file, plus the end of MP4
/// family files, because the `moov` index of an m4b/m4a may sit at the end of the file.
public enum WindowPlanner {
    public struct TrackInfo: Sendable, Equatable {
        public let index: Int
        public let startOffset: Double
        public let duration: Double
        public let size: Int64
        public let ext: String

        public init(index: Int, startOffset: Double, duration: Double, size: Int64, ext: String) {
            self.index = index
            self.startOffset = startOffset
            self.duration = duration
            self.size = size
            self.ext = ext
        }

        var isMP4Family: Bool {
            ["m4b", "m4a", "mp4", "aac", "alac"].contains(ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
    }

    public struct TrackPlan: Sendable, Equatable {
        public let trackIndex: Int
        public let ranges: [Range<Int64>]
    }

    public static let headerBytes: Int64 = 1 << 20          // 1 MiB
    public static let marginFraction = 0.10                 // 10 % of the window's bytes on each side
    public static let minimumMarginBytes: Int64 = 256 << 10 // 256 KiB

    /// - Parameters:
    ///   - start: window start, in seconds from the beginning of the book
    ///   - duration: window length in seconds
    public static func plan(tracks: [TrackInfo], start: Double, duration: Double) -> [TrackPlan] {
        let end = start + duration
        var plans: [TrackPlan] = []

        for track in tracks where track.size > 0 && track.duration > 0 {
            let trackEnd = track.startOffset + track.duration
            guard track.startOffset < end, trackEnd > start else { continue }

            let localStart = max(0, start - track.startOffset)
            let localEnd = min(track.duration, end - track.startOffset)
            let bytesPerSecond = Double(track.size) / track.duration

            var lower = Int64(localStart * bytesPerSecond)
            var upper = Int64((localEnd * bytesPerSecond).rounded(.up))
            let margin = max(minimumMarginBytes, Int64(Double(upper - lower) * marginFraction))
            lower = max(0, lower - margin)
            upper = min(track.size, upper + margin)

            var index = ByteRangeIndex([lower..<upper])
            index.insert(0..<min(headerBytes, track.size))
            if track.isMP4Family {
                index.insert(max(0, track.size - headerBytes)..<track.size)
            }
            plans.append(TrackPlan(trackIndex: track.index, ranges: index.ranges))
        }
        return plans
    }
}
