import Foundation

/// A local file with the full size of a remote audio file, of which only some byte ranges are filled.
/// Unwritten regions are holes on APFS and take no disk space. A JSON manifest next to the data file
/// records which ranges are present; it is written after the data so a crash never marks missing bytes as present.
public final class SparseTrackFile: @unchecked Sendable {
    public let dataURL: URL
    public let contentLength: Int64
    private let manifestURL: URL
    private let lock = NSLock()
    private var index: ByteRangeIndex

    private struct Manifest: Codable {
        var contentLength: Int64
        var index: ByteRangeIndex
    }

    /// Opens the file at `dataURL`, creating it (and its manifest) when missing or when the size changed on the server.
    public init(dataURL: URL, contentLength: Int64) throws {
        self.dataURL = dataURL
        self.contentLength = contentLength
        self.manifestURL = dataURL.appendingPathExtension("ranges.json")

        let fm = FileManager.default
        try fm.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.contentLength == contentLength,
           fm.fileExists(atPath: dataURL.path) {
            index = manifest.index
        } else {
            try? fm.removeItem(at: dataURL)
            guard fm.createFile(atPath: dataURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dataURL.path])
            }
            let handle = try FileHandle(forWritingTo: dataURL)
            try handle.truncate(atOffset: UInt64(contentLength))
            try handle.close()
            index = ByteRangeIndex()
            try saveManifest()
        }
    }

    public var presentRanges: ByteRangeIndex {
        lock.withLock { index }
    }

    public var isComplete: Bool {
        presentRanges.contains(0..<contentLength)
    }

    public func missing(in range: Range<Int64>) -> [Range<Int64>] {
        presentRanges.missing(in: range.clamped(to: 0..<contentLength))
    }

    public func write(_ data: Data, at offset: Int64) throws {
        let range = offset..<(offset + Int64(data.count))
        guard range.lowerBound >= 0, range.upperBound <= contentLength else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "Range \(range) outside file of \(contentLength) bytes"])
        }
        try lock.withLock {
            let handle = try FileHandle(forWritingTo: dataURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            try handle.synchronize()
            index.insert(range)
            try saveManifest()
        }
    }

    /// Bytes actually allocated on disk (holes excluded).
    public var allocatedBytes: Int64 {
        let values = try? dataURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }

    public func delete() {
        lock.withLock {
            try? FileManager.default.removeItem(at: dataURL)
            try? FileManager.default.removeItem(at: manifestURL)
            index = ByteRangeIndex()
        }
    }

    private func saveManifest() throws {
        let data = try JSONEncoder().encode(Manifest(contentLength: contentLength, index: index))
        try data.write(to: manifestURL, options: .atomic)
    }
}
