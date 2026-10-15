import AbsWatchCore
import Foundation

/// Downloads byte ranges of track files into `SparseTrackFile`s, in chunks so progress survives interruptions.
///
/// Two URLSessions: a default one (fast, but its tasks die when the app is suspended) and a background one (keeps
/// going while the app is suspended, but watchOS schedules it slowly). `DownloadManager` decides which one to use.
final class TrackDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Job: Codable, Sendable, Hashable {
        let key: String
        /// Path of the data file relative to `root`
        let path: String
        let contentUrl: String
        let contentLength: Int64
        let lower: Int64
        let upper: Int64

        var id: String { "\(path)#\(lower)" }
    }

    static let backgroundIdentifier = "kw.audiobookshelf.watch.downloads"
    static let chunkBytes: Int64 = 4 << 20

    let root: URL
    private var foreground: URLSession!
    private var background: URLSession!
    private let lock = NSLock()
    private var files: [String: SparseTrackFile] = [:]
    /// Job id → session that runs it
    private var inFlight: [String: (job: Job, background: Bool)] = [:]
    /// Bytes received per item since launch, for the speed display
    private var received: [String: Int64] = [:]

    /// Called on the main queue when the system has delivered all events for the background session.
    var backgroundEventsCompletion: (() -> Void)?
    /// Builds the authenticated range request.
    var makeRequest: (@Sendable (Job, _ token: String) -> URLRequest)?
    /// Returns a fresh access token after a download got 401 (access tokens live 1 h, downloads can take longer).
    var refreshToken: (@Sendable (_ failedToken: String) async -> String?)?
    /// A chunk was written, or a job ended with an error (nil when it succeeded). Called on a background queue.
    var onChange: (@Sendable (_ key: String, _ error: String?) -> Void)?

    init(root: URL) {
        self.root = root
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        foreground = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        background = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        // Background tasks survive app restarts; pick them up again
        background.getAllTasks { tasks in
            self.lock.withLock {
                for task in tasks {
                    guard let job = Self.job(of: task) else { continue }
                    self.inFlight[job.id] = (job, true)
                }
            }
        }
    }

    func file(path: String, contentLength: Int64) throws -> SparseTrackFile {
        try lock.withLock {
            if let file = files[path], file.contentLength == contentLength { return file }
            let file = try SparseTrackFile(dataURL: root.appending(path: path), contentLength: contentLength)
            files[path] = file
            return file
        }
    }

    func receivedBytes(key: String) -> Int64 {
        lock.withLock { received[key] ?? 0 }
    }

    func isActive(key: String) -> Bool {
        lock.withLock { inFlight.values.contains { $0.job.key == key } }
    }

    /// Queues the parts of `ranges` that are neither on disk nor already queued. Returns the number of bytes queued.
    @discardableResult
    func enqueue(key: String, path: String, contentUrl: String, contentLength: Int64, ranges: [Range<Int64>],
                 token: String, inBackground: Bool, urgent: Bool = false, cellular: Bool) throws -> Int64 {
        let file = try file(path: path, contentLength: contentLength)
        var queued: Int64 = 0
        for range in ranges {
            for gap in file.missing(in: range) {
                var lower = gap.lowerBound
                while lower < gap.upperBound {
                    let upper = min(lower + Self.chunkBytes, gap.upperBound)
                    let job = Job(key: key, path: path, contentUrl: contentUrl, contentLength: contentLength, lower: lower, upper: upper)
                    lower = upper
                    let isNew = lock.withLock {
                        guard inFlight[job.id] == nil else { return false }
                        inFlight[job.id] = (job, inBackground)
                        return true
                    }
                    guard isNew else { continue }
                    start(job, token: token, inBackground: inBackground, urgent: urgent, cellular: cellular)
                    queued += job.upper - job.lower
                }
            }
        }
        return queued
    }

    /// Stops the jobs of one item, or all (`key == nil`).
    func cancel(key: String? = nil) {
        lock.withLock { inFlight = inFlight.filter { key != nil && $0.value.job.key != key } }
        for session in [foreground!, background!] {
            session.getAllTasks { tasks in
                for task in tasks where key == nil || Self.job(of: task)?.key == key { task.cancel() }
            }
        }
        if let key {
            lock.withLock { files = files.filter { !$0.key.hasPrefix(key + "/") } }
        } else {
            lock.withLock { files = [:] }
        }
    }

    /// Cancels the jobs running in the other session and returns them, so they can be queued again in the wanted one.
    func takeJobs(inBackground: Bool) -> [Job] {
        let taken = lock.withLock {
            let jobs = inFlight.values.filter { $0.background == inBackground }.map(\.job)
            for job in jobs { inFlight[job.id] = nil }
            return jobs
        }
        let ids = Set(taken.map(\.id))
        (inBackground ? background : foreground).getAllTasks { tasks in
            for task in tasks where Self.job(of: task).map({ ids.contains($0.id) }) == true { task.cancel() }
        }
        return taken
    }

    private func start(_ job: Job, token: String, inBackground: Bool, urgent: Bool, cellular: Bool) {
        guard let makeRequest, let description = try? JSONEncoder().encode(job) else { return }
        var request = makeRequest(job, token)
        request.allowsCellularAccess = cellular
        let task = (inBackground ? background : foreground).downloadTask(with: request)
        task.taskDescription = String(decoding: description, as: UTF8.self)
        if urgent { task.priority = URLSessionTask.highPriority }
        task.resume()
    }

    private static func job(of task: URLSessionTask) -> Job? {
        guard let description = task.taskDescription else { return nil }
        return try? JSONDecoder().decode(Job.self, from: Data(description.utf8))
    }

    private func finish(_ job: Job, session: URLSession, error: String?) {
        let isBackground = session === background
        lock.withLock {
            if inFlight[job.id]?.background == isBackground { inFlight[job.id] = nil }
        }
        onChange?(job.key, error)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = Self.job(of: downloadTask) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        do {
            var data = try Data(contentsOf: location)
            switch http?.statusCode ?? 0 {
            case 206:
                if let contentRange = http?.value(forHTTPHeaderField: "Content-Range"), !contentRange.hasPrefix("bytes \(job.lower)-") {
                    return finish(job, session: session, error: "Unexpected range from server")
                }
            case 200 where job.lower == 0:
                // The server ignored the Range header and sent the whole file; keep what was asked for
                data = data.prefix(Int(job.upper))
            case 401:
                let failed = String(downloadTask.originalRequest?.value(forHTTPHeaderField: "Authorization")?.dropFirst("Bearer ".count) ?? "")
                let cellular = downloadTask.originalRequest?.allowsCellularAccess ?? true
                Task {
                    guard let fresh = await refreshToken?(failed) else {
                        return finish(job, session: session, error: "Signed out")
                    }
                    start(job, token: fresh, inBackground: session === background, urgent: false, cellular: cellular)
                }
                return
            case let status:
                return finish(job, session: session, error: "Server error \(status)")
            }
            try file(path: job.path, contentLength: job.contentLength).write(data, at: job.lower)
            finish(job, session: session, error: nil)
        } catch {
            finish(job, session: session, error: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = Self.job(of: downloadTask) else { return }
        lock.withLock { received[job.key, default: 0] += bytesWritten }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let job = Self.job(of: task) else { return }
        if (error as? URLError)?.code == .cancelled {
            // Cancelled on purpose (removed, or moved to the other session); the job list was already updated
            return
        }
        finish(job, session: session, error: error.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundEventsCompletion?()
            self.backgroundEventsCompletion = nil
        }
    }
}
