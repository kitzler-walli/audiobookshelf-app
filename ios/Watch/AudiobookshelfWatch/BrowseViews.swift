import AbsWatchCore
import SwiftUI

struct LibrariesView: View {
    @State private var libraries: [Library] = []
    @State private var loaded = false
    @State private var loadError: String?

    var body: some View {
        List {
            if !loaded {
                ProgressView()
            } else if libraries.isEmpty {
                Text(loadError ?? "No libraries").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(libraries) { library in
                NavigationLink(value: Route.library(library)) {
                    Label(library.name, systemImage: library.isPodcast ? "mic" : "books.vertical")
                }
            }
        }
        .navigationTitle("Libraries")
        .task {
            guard !loaded, let client = AppModel.shared.client else { return }
            do {
                libraries = try await client.libraries()
            } catch {
                AppModel.shared.handle(error)
                loadError = error.localizedDescription
            }
            loaded = true
        }
    }
}

struct LibraryItemsView: View {
    let library: Library

    @State private var items: [LibraryItemSummary] = []
    @State private var progress: [String: MediaProgress] = [:]
    @State private var nextPage = 0
    @State private var total: Int?
    @State private var isLoading = false
    @State private var loadError: String?

    private static let pageSize = 30

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink(value: Route.item(id: item.id, episodeId: nil)) {
                    ItemRow(item: item, progress: progress[item.id])
                }
                .onAppear {
                    if item.id == items.last?.id { Task { await loadMore() } }
                }
            }
            if isLoading {
                ProgressView()
            } else if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("Empty library").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(library.name)
        .task {
            guard items.isEmpty else { return }
            if let client = AppModel.shared.client, let all = try? await client.allMediaProgress() {
                progress = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            }
            await loadMore()
        }
    }

    private var hasMore: Bool {
        guard let total else { return true }
        return items.count < total
    }

    private func loadMore() async {
        guard !isLoading, hasMore, let client = AppModel.shared.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.libraryItems(libraryId: library.id, page: nextPage, limit: Self.pageSize)
            items.append(contentsOf: page.results)
            total = page.total ?? (page.results.count < Self.pageSize ? items.count : nil)
            nextPage += 1
            loadError = nil
        } catch {
            AppModel.shared.handle(error)
            loadError = error.localizedDescription
        }
    }
}

struct ItemDetailView: View {
    let libraryItemId: String
    let episodeId: String?

    @State private var item: LibraryItemDetail?
    @State private var loadError: String?
    @State private var downloadError: String?
    @State private var showDownloadOptions = false
    @State private var confirmRemove = false
    private let player = PlayerController.shared
    private let downloads = DownloadManager.shared

    /// The download of this book (or of the opened episode)
    private var downloaded: DownloadedItem? {
        downloads.item(libraryItemId: libraryItemId, episodeId: episodeId)
    }

    var body: some View {
        List {
            if let item {
                header(item)
                if item.isPodcast {
                    episodes(item)
                } else {
                    playButton(item)
                    downloadSection(item)
                    chapters(item.media.chapters ?? []) { await play(startTime: $0) }
                    if let description = item.media.metadata.descriptionPlain, !description.isEmpty {
                        Section("About") {
                            Text(description).font(.footnote).lineLimit(8)
                        }
                    }
                }
            } else if let downloaded, loadError != nil {
                offlineDetail(downloaded)
            } else if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item?.title ?? downloaded?.title ?? "")
        .task { await load() }
        .confirmationDialog("Download to this watch", isPresented: $showDownloadOptions) {
            if let item {
                Button("Whole book (\(ByteCountFormatter.string(fromByteCount: totalBytes(item), countStyle: .file)))") { startDownload(item, scope: .full) }
                Button("Next 2 hours") { startDownload(item, scope: .ahead(seconds: 7200)) }
                Button("Next hour") { startDownload(item, scope: .ahead(seconds: 3600)) }
            }
        } message: {
            Text("\"Next\" keeps the coming hours downloaded and moves along while you listen.")
        }
        .confirmationDialog("Remove the download from this watch?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                if let downloaded { downloads.remove(downloaded.id) }
            }
        }
    }

    private func load() async {
        guard let client = AppModel.shared.client else { return }
        do {
            item = try await client.item(id: libraryItemId, episodeId: episodeId)
        } catch {
            AppModel.shared.handle(error)
            loadError = HomeView.describe(error)
        }
    }

    /// Without a connection: what the download knows.
    @ViewBuilder
    private func offlineDetail(_ downloaded: DownloadedItem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                CoverImage(libraryItemId: downloaded.libraryItemId, size: 90)
                    .frame(maxWidth: .infinity)
                Text(downloaded.title).font(.headline).lineLimit(3)
                if let author = downloaded.author {
                    Text(author).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
        }
        Section {
            Button {
                Task { await play(startTime: nil) }
            } label: {
                Label(player.libraryItemId == downloaded.libraryItemId ? "Continue" : "Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.orange)
            .disabled(player.isLoading)
            if let position = downloaded.position, position > 0 {
                Text("\(TimeText.duration(max(0, downloaded.duration - position))) left").font(.caption2).foregroundStyle(.secondary)
            }
            DownloadStatusText(item: downloaded)
            if let error = player.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        chapters(downloaded.chapters) { await play(startTime: $0) }
    }

    private func totalBytes(_ item: LibraryItemDetail) -> Int64 {
        (item.media.tracks ?? []).reduce(0) { $0 + ($1.metadata?.size ?? 0) }
    }

    private func startDownload(_ item: LibraryItemDetail, episode: Episode? = nil, scope: DownloadScope) {
        downloadError = nil
        Task {
            do {
                try await downloads.download(item, episode: episode, scope: scope)
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func downloadSection(_ item: LibraryItemDetail) -> some View {
        Section {
            if let downloaded {
                DownloadStatusText(item: downloaded)
                if let status = downloads.status[downloaded.id], !status.isComplete {
                    ProgressView(value: status.fraction).tint(.orange)
                }
                Button("Remove download", role: .destructive) { confirmRemove = true }
            } else {
                Button {
                    showDownloadOptions = true
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled((item.media.tracks ?? []).isEmpty)
            }
            if let downloadError {
                Text(downloadError).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func header(_ item: LibraryItemDetail) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                CoverImage(libraryItemId: item.id, size: 90)
                    .frame(maxWidth: .infinity)
                Text(item.title).font(.headline).lineLimit(3)
                if let author = item.authorName {
                    Text(author).font(.footnote).foregroundStyle(.secondary)
                }
                if let narrator = item.narratorName {
                    Text("Read by \(narrator)").font(.caption2).foregroundStyle(.secondary)
                }
                if let series = item.seriesName {
                    Text(series).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func playButton(_ item: LibraryItemDetail) -> some View {
        let progress = item.userMediaProgress
        let isCurrent = player.libraryItemId == item.id
        Section {
            Button {
                Task { await play(startTime: nil) }
            } label: {
                Label(playTitle(progress: progress, isCurrent: isCurrent), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.orange)
            .disabled(player.isLoading)

            if let progress, !progress.isFinished, progress.progress > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: min(1, progress.progress)).tint(.orange)
                    Text("\(TimeText.duration(progress.remaining)) left").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let duration = item.media.duration {
                Text(TimeText.duration(duration)).font(.caption2).foregroundStyle(.secondary)
            }
            if let error = player.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func playTitle(progress: MediaProgress?, isCurrent: Bool) -> String {
        if isCurrent { return "Continue" }
        guard let progress else { return "Play" }
        if progress.isFinished { return "Listen again" }
        return progress.currentTime > 0 ? "Resume" : "Play"
    }

    @ViewBuilder
    private func chapters(_ chapters: [Chapter], play: @escaping (Double) async -> Void) -> some View {
        if chapters.count > 1 {
            Section("Chapters") {
                ForEach(chapters) { chapter in
                    Button {
                        Task { await play(chapter.start) }
                    } label: {
                        HStack {
                            Text(chapter.title).font(.footnote).lineLimit(2)
                            Spacer(minLength: 4)
                            Text(TimeText.duration(chapter.end - chapter.start)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func episodes(_ item: LibraryItemDetail) -> some View {
        Section("Episodes") {
            ForEach(item.episodes) { episode in
                let download = downloads.item(libraryItemId: item.id, episodeId: episode.id)
                Button {
                    Task { await play(episodeId: episode.id, startTime: nil) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title ?? "Episode").font(.footnote).lineLimit(2)
                        if let download {
                            DownloadStatusText(item: download)
                        } else if let duration = episode.duration {
                            Text(TimeText.duration(duration)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    if let download {
                        Button(role: .destructive) { downloads.remove(download.id) } label: { Label("Remove", systemImage: "trash") }
                    } else if episode.audioTrack != nil {
                        Button { startDownload(item, episode: episode, scope: .full) } label: { Label("Download", systemImage: "arrow.down.circle") }
                            .tint(.orange)
                    }
                }
            }
            if let downloadError {
                Text(downloadError).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func play(episodeId: String? = nil, startTime: Double?) async {
        guard let client = AppModel.shared.client else { return }
        await player.play(libraryItemId: libraryItemId, episodeId: episodeId ?? self.episodeId, startTime: startTime, client: client)
        if player.isActive, player.errorMessage == nil {
            Router.shared.showNowPlaying()
        }
    }
}
