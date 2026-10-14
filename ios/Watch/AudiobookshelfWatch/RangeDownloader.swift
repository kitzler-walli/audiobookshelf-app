import AbsWatchCore
import Foundation

/// Downloads byte ranges of track files into `SparseTrackFile`s.
/// Spike test 3 compares a background `URLSession` (keeps going while the app is suspended) with a default one.
final class RangeDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Job: Codable, Sendable {
        /// Path of the data file relative to `root`
        let path: String
        /// Absolute file URL, e.g. https://server/api/items/<id>/file/<ino>
        let contentUrl: String
        let contentLength: Int64
        let lower: Int64
        let upper: Int64

        var contentUrlBase: URL { URL(string: contentUrl)! }
    }

    static let backgroundIdentifier = "kw.audiobookshelf.watch.downloads"
    /// Large ranges are split so progress survives interruptions and the in-memory chunk stays small.
    static let chunkBytes: Int64 = 4 << 20

    let name: String
    let root: URL
    private(set) var session: URLSession!
    private var files: [String: SparseTrackFile] = [:]
    private let filesLock = NSLock()

    /// Called on the main queue when the system has delivered all events for the background session.
    var backgroundEventsCompletion: (() -> Void)?
    /// Builds the authenticated range request for a job.
    var makeRequest: (@Sendable (Job, _ token: String) -> URLRequest)?
    /// Returns a fresh access token after a download got 401 (access tokens live 1 h, downloads can run longer).
    var refreshToken: (@Sendable (_ failedToken: String) async -> String?)?

    init(background: Bool, root: URL) {
        self.name = background ? "bg" : "fg"
        self.root = root
        super.init()
        let configuration: URLSessionConfiguration
        if background {
            configuration = .background(withIdentifier: Self.backgroundIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
        } else {
            configuration = .default
        }
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func file(path: String, contentLength: Int64) throws -> SparseTrackFile {
        try filesLock.withLock {
            if let file = files[path], file.contentLength == contentLength { return file }
            let file = try SparseTrackFile(dataURL: root.appending(path: path), contentLength: contentLength)
            files[path] = file
            return file
        }
    }

    /// Queues downloads for the parts of `ranges` that are not on disk yet. Returns the number of bytes queued.
    @discardableResult
    func enqueue(path: String, contentUrl: String, contentLength: Int64, ranges: [Range<Int64>], token: String) throws -> Int64 {
        let file = try file(path: path, contentLength: contentLength)
        var queued: Int64 = 0
        for range in ranges {
            for gap in file.missing(in: range) {
                var lower = gap.lowerBound
                while lower < gap.upperBound {
                    let upper = min(lower + Self.chunkBytes, gap.upperBound)
                    try start(Job(path: path, contentUrl: contentUrl, contentLength: contentLength, lower: lower, upper: upper), token: token)
                    queued += upper - lower
                    lower = upper
                }
            }
        }
        SpikeLog.post("[\(name)] queued \(ByteCountFormatter.string(fromByteCount: queued, countStyle: .file)) for \(path)")
        return queued
    }

    private func start(_ job: Job, token: String) throws {
        guard let makeRequest else { return }
        let task = session.downloadTask(with: makeRequest(job, token))
        task.taskDescription = String(data: try JSONEncoder().encode(job), encoding: .utf8)
        task.resume()
    }

    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription,
              let job = try? JSONDecoder().decode(Job.self, from: Data(description.utf8)) else { return }
        do {
            let http = downloadTask.response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var data = try Data(contentsOf: location)
            switch status {
            case 206:
                if let contentRange = http?.value(forHTTPHeaderField: "Content-Range"),
                   !contentRange.hasPrefix("bytes \(job.lower)-") {
                    SpikeLog.post("[\(name)] unexpected Content-Range \(contentRange) for \(job.lower)..<\(job.upper)")
                    return
                }
            case 401:
                let failed = String(downloadTask.originalRequest?.value(forHTTPHeaderField: "Authorization")?.dropFirst("Bearer ".count) ?? "")
                Task {
                    guard let fresh = await refreshToken?(failed) else {
                        SpikeLog.post("[\(name)] 401 and token refresh failed for \(job.path)")
                        return
                    }
                    try? start(job, token: fresh)
                }
                return
            case 200 where job.lower == 0:
                // Server ignored the Range header and sent the whole file; keep what we asked for.
                data = data.prefix(Int(job.upper))
            default:
                SpikeLog.post("[\(name)] HTTP \(status) for \(job.path) \(job.lower)..<\(job.upper)")
                return
            }
            try file(path: job.path, contentLength: job.contentLength).write(data, at: job.lower)
        } catch {
            SpikeLog.post("[\(name)] write failed: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as? URLError)?.code != .cancelled {
            SpikeLog.post("[\(name)] task failed: \(error.localizedDescription)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        SpikeLog.post("[\(name)] background events finished")
        DispatchQueue.main.async {
            self.backgroundEventsCompletion?()
            self.backgroundEventsCompletion = nil
        }
    }
}
