import Foundation

/// Sorted, non-overlapping set of byte ranges that are present on disk.
/// Adjacent and overlapping ranges are merged on insert.
public struct ByteRangeIndex: Codable, Equatable, Sendable {
    public private(set) var ranges: [Range<Int64>] = []

    public init(_ ranges: [Range<Int64>] = []) {
        for r in ranges { insert(r) }
    }

    public var totalBytes: Int64 {
        ranges.reduce(0) { $0 + Int64($1.count) }
    }

    public mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var lower = range.lowerBound
        var upper = range.upperBound
        var result: [Range<Int64>] = []
        var inserted = false
        for r in ranges {
            if r.upperBound < lower {
                result.append(r)
            } else if r.lowerBound > upper {
                if !inserted {
                    result.append(lower..<upper)
                    inserted = true
                }
                result.append(r)
            } else {
                // Overlapping or touching: absorb into the new range
                lower = min(lower, r.lowerBound)
                upper = max(upper, r.upperBound)
            }
        }
        if !inserted { result.append(lower..<upper) }
        ranges = result
    }

    public func contains(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        return ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    /// Parts of `range` that are not yet present.
    public func missing(in range: Range<Int64>) -> [Range<Int64>] {
        guard !range.isEmpty else { return [] }
        var gaps: [Range<Int64>] = []
        var cursor = range.lowerBound
        for r in ranges where r.upperBound > cursor {
            if r.lowerBound >= range.upperBound { break }
            if r.lowerBound > cursor {
                gaps.append(cursor..<min(r.lowerBound, range.upperBound))
            }
            cursor = max(cursor, r.upperBound)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound { gaps.append(cursor..<range.upperBound) }
        return gaps
    }
}
