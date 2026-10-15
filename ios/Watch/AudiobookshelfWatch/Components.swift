import AbsWatchCore
import SwiftUI
import UIKit

enum Route: Hashable {
    case item(id: String, episodeId: String?)
    case libraries
    case library(Library)
    case nowPlaying
    case chapters
    case settings
    case downloads
    case log
}

@MainActor @Observable
final class Router {
    static let shared = Router()
    var path = NavigationPath()

    func showNowPlaying() {
        path.append(Route.nowPlaying)
    }
}

extension MediaProgress {
    /// Matches `LibraryItemSummary.progressKey`.
    var key: String {
        guard let libraryItemId else { return episodeId ?? "" }
        return episodeId.map { "\(libraryItemId)-\($0)" } ?? libraryItemId
    }
}

extension LibraryItemSummary {
    var progressKey: String {
        recentEpisode.map { "\(id)-\($0.id)" } ?? id
    }
}

enum TimeText {
    /// "2 h 13 min", "45 min", "30 s"
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }
}

struct CoverImage: View {
    let libraryItemId: String
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = localCover {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let client = AppModel.shared.client {
                AsyncImage(url: client.coverURL(libraryItemId: libraryItemId, width: Int(size * 3))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
    }

    /// Saved with a download, so covers show offline too.
    private var localCover: UIImage? {
        let manager = DownloadManager.shared
        guard let item = manager.items.first(where: { $0.libraryItemId == libraryItemId }) else { return nil }
        return UIImage(contentsOfFile: manager.store.coverURL(for: item.id).path)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size / 8)
            .fill(.gray.opacity(0.3))
            .overlay(Image(systemName: "book.closed").font(.system(size: size / 2.5)).foregroundStyle(.secondary))
    }
}

struct ItemRow: View {
    let item: LibraryItemSummary
    var progress: MediaProgress?

    var body: some View {
        HStack(spacing: 8) {
            CoverImage(libraryItemId: item.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2)
                if let author = item.authorName {
                    Text(author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let progress, progress.progress > 0, !progress.isFinished {
                    ProgressView(value: min(1, progress.progress)).tint(.orange)
                    Text("\(TimeText.duration(progress.remaining)) left").font(.caption2).foregroundStyle(.secondary)
                } else if progress?.isFinished == true {
                    Label("Finished", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A download in lists: progress while downloading, size when done.
struct DownloadStatusText: View {
    let item: DownloadedItem
    private let manager = DownloadManager.shared

    var body: some View {
        let status = manager.status[item.id] ?? DownloadManager.Status()
        Group {
            if status.isComplete {
                switch item.scope {
                case .full: Label("Downloaded", systemImage: "arrow.down.circle.fill")
                case .ahead(let seconds): Label("Next \(TimeText.duration(seconds)) downloaded", systemImage: "arrow.down.circle.fill")
                }
            } else if let error = status.error, !status.isActive {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Label("\(Int(status.fraction * 100)) % of \(ByteCountFormatter.string(fromByteCount: status.plannedBytes, countStyle: .file))",
                          systemImage: status.isActive ? "arrow.down.circle" : "pause.circle")
                    if status.isActive {
                        Text(Self.speedText(status)).monospacedDigit()
                    }
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    /// "1.2 MB/s · 8 min left"
    static func speedText(_ status: DownloadManager.Status) -> String {
        guard let speed = status.bytesPerSecond else { return "Starting…" }
        guard speed >= 1024 else { return "Waiting for network…" }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
        guard let remaining = status.remainingSeconds else { return rate }
        return "\(rate) · \(TimeText.duration(max(60, remaining))) left"
    }
}

/// Compact "now playing" entry for the home list.
struct NowPlayingRow: View {
    private let player = PlayerController.shared

    var body: some View {
        HStack(spacing: 8) {
            if let id = player.libraryItemId {
                CoverImage(libraryItemId: id)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(player.currentChapter?.title ?? player.author ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                .foregroundStyle(.orange)
        }
    }
}
