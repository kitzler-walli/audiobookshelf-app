import Foundation
import Observation
import os

/// In-app log so what happened can be read (and sent) from the watch without a debugger attached.
/// Kept in a file so it survives the app being quit by the system.
@MainActor @Observable
final class AppLog {
    static let shared = AppLog()
    private static let maxLines = 1000

    /// Newest first
    private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "kw.audiobookshelf.watch", category: "app")
    private let fileURL = URL.applicationSupportDirectory.appending(path: "app.log")
    private var saveScheduled = false
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm:ss"
        return f
    }()

    private init() {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = text.split(separator: "\n").map(String.init).reversed()
        }
    }

    func add(_ message: String) {
        logger.info("\(message, privacy: .public)")
        lines.insert("\(formatter.string(from: Date())) \(message)", at: 0)
        if lines.count > Self.maxLines { lines.removeLast(lines.count - Self.maxLines) }
        scheduleSave()
    }

    nonisolated static func post(_ message: String) {
        Task { @MainActor in AppLog.shared.add(message) }
    }

    /// Bursts of entries (download chunks) are written once.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saveScheduled = false
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? lines.reversed().joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
