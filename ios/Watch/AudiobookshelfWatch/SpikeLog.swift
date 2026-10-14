import Foundation
import Observation
import os

/// In-app log so spike results can be read on the watch without a debugger attached.
@MainActor @Observable
final class SpikeLog {
    static let shared = SpikeLog()

    private(set) var lines: [String] = []
    private let logger = Logger(subsystem: "kw.audiobookshelf.watch", category: "spike")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ message: String) {
        logger.info("\(message, privacy: .public)")
        lines.insert("\(formatter.string(from: Date())) \(message)", at: 0)
        if lines.count > 200 { lines.removeLast(lines.count - 200) }
    }

    nonisolated static func post(_ message: String) {
        Task { @MainActor in SpikeLog.shared.add(message) }
    }
}
