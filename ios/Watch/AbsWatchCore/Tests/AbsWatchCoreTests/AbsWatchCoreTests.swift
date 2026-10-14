import Foundation
import Testing
@testable import AbsWatchCore

@Suite struct ByteRangeIndexTests {
    @Test func mergesOverlappingAndAdjacentRanges() {
        var index = ByteRangeIndex()
        index.insert(10..<20)
        index.insert(30..<40)
        index.insert(20..<25)   // touches the first range
        index.insert(35..<50)   // overlaps the second range
        #expect(index.ranges == [10..<25, 30..<50])
        index.insert(0..<100)
        #expect(index.ranges == [0..<100])
    }

    @Test func insertsBetweenExistingRanges() {
        var index = ByteRangeIndex([0..<10, 50..<60])
        index.insert(20..<30)
        #expect(index.ranges == [0..<10, 20..<30, 50..<60])
        #expect(index.totalBytes == 30)
    }

    @Test func reportsMissingRanges() {
        let index = ByteRangeIndex([10..<20, 30..<40])
        #expect(index.missing(in: 0..<50) == [0..<10, 20..<30, 40..<50])
        #expect(index.missing(in: 12..<18) == [])
        #expect(index.missing(in: 15..<35) == [20..<30])
        #expect(index.contains(10..<20))
        #expect(!index.contains(15..<35))
    }
}

@Suite struct SparseTrackFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sparse-\(UUID().uuidString)/track.m4b")
    }

    @Test func writesRangesAndPersistsManifest() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let file = try SparseTrackFile(dataURL: url, contentLength: 1_000_000)
        try file.write(Data(repeating: 0xAB, count: 1000), at: 500_000)
        #expect(file.missing(in: 0..<1_000_000) == [0..<500_000, 501_000..<1_000_000])
        #expect(try Data(contentsOf: url).count == 1_000_000)

        let reopened = try SparseTrackFile(dataURL: url, contentLength: 1_000_000)
        #expect(reopened.presentRanges.ranges == [500_000..<501_000])
        let bytes = try Data(contentsOf: url)[500_000..<501_000]
        #expect(bytes.allSatisfy { $0 == 0xAB })
    }

    @Test func resetsWhenServerSizeChanges() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let file = try SparseTrackFile(dataURL: url, contentLength: 1000)
        try file.write(Data(count: 100), at: 0)
        let reopened = try SparseTrackFile(dataURL: url, contentLength: 2000)
        #expect(reopened.presentRanges.ranges.isEmpty)
    }

    @Test func onlyAllocatesWrittenRanges() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let size: Int64 = 300 << 20
        let file = try SparseTrackFile(dataURL: url, contentLength: size)
        try file.write(Data(repeating: 1, count: 1 << 20), at: 0)
        try file.write(Data(repeating: 2, count: 4 << 20), at: 150 << 20)
        try file.write(Data(repeating: 3, count: 1 << 20), at: size - (1 << 20))
        #expect(file.allocatedBytes < 16 << 20, "allocated \(file.allocatedBytes) bytes for 6 MiB of data")
    }

    @Test func rejectsWritesOutsideFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let file = try SparseTrackFile(dataURL: url, contentLength: 1000)
        #expect(throws: (any Error).self) { try file.write(Data(count: 10), at: 995) }
    }
}

@Suite struct WindowPlannerTests {
    private let mib: Int64 = 1 << 20

    @Test func singleM4bIncludesHeaderTailAndWindow() {
        // 10 h book, 360 MiB → 36 MiB per hour
        let track = WindowPlanner.TrackInfo(index: 1, startOffset: 0, duration: 36_000, size: 360 * mib, ext: "m4b")
        let plans = WindowPlanner.plan(tracks: [track], start: 3600, duration: 3600)
        #expect(plans.count == 1)
        let ranges = plans[0].ranges
        #expect(ranges.first?.lowerBound == 0)                   // header
        #expect(ranges.last?.upperBound == 360 * mib)            // moov may be at the end
        let window = ranges.first { $0.contains(36 * mib) && $0.contains(72 * mib - 1) }
        #expect(window != nil)                                   // the hour itself
        let total = ranges.reduce(Int64(0)) { $0 + Int64($1.count) }
        #expect(total < 50 * mib)                                // not the whole book
    }

    @Test func multiFileBookOnlyPlansOverlappingTracksWithoutTail() {
        let tracks = (0..<10).map { i in
            WindowPlanner.TrackInfo(index: i + 1, startOffset: Double(i) * 1800, duration: 1800, size: 30 * mib, ext: "mp3")
        }
        // 1 h starting in the middle of track 3 → tracks 3, 4, 5
        let plans = WindowPlanner.plan(tracks: tracks, start: 2 * 1800 + 900, duration: 3600)
        #expect(plans.map(\.trackIndex) == [3, 4, 5])
        #expect(plans[1].ranges == [0..<30 * mib])               // fully inside the window
        #expect(plans[0].ranges.last?.upperBound == 30 * mib)    // runs to the end of track 3
        #expect(plans[2].ranges.count == 1)                      // header merges with the window start
    }

    @Test func skipsTracksWithoutSize() {
        let track = WindowPlanner.TrackInfo(index: 1, startOffset: 0, duration: 100, size: 0, ext: "mp3")
        #expect(WindowPlanner.plan(tracks: [track], start: 0, duration: 50).isEmpty)
    }
}
