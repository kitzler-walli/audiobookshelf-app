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
    private let player = PlayerController.shared

    var body: some View {
        List {
            if let item {
                header(item)
                if item.isPodcast {
                    episodes(item)
                } else {
                    playButton(item)
                    chapters(item)
                    if let description = item.media.metadata.descriptionPlain, !description.isEmpty {
                        Section("About") {
                            Text(description).font(.footnote).lineLimit(8)
                        }
                    }
                }
            } else if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item?.title ?? "")
        .task { await load() }
    }

    private func load() async {
        guard let client = AppModel.shared.client else { return }
        do {
            item = try await client.item(id: libraryItemId, episodeId: episodeId)
        } catch {
            AppModel.shared.handle(error)
            loadError = error.localizedDescription
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
                Task { await play(item, startTime: nil) }
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
    private func chapters(_ item: LibraryItemDetail) -> some View {
        if let chapters = item.media.chapters, chapters.count > 1 {
            Section("Chapters") {
                ForEach(chapters) { chapter in
                    Button {
                        Task { await play(item, startTime: chapter.start) }
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
                Button {
                    Task { await play(item, episodeId: episode.id, startTime: nil) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title ?? "Episode").font(.footnote).lineLimit(2)
                        if let duration = episode.duration {
                            Text(TimeText.duration(duration)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func play(_ item: LibraryItemDetail, episodeId: String? = nil, startTime: Double?) async {
        guard let client = AppModel.shared.client else { return }
        await player.play(libraryItemId: item.id, episodeId: episodeId ?? self.episodeId, startTime: startTime, client: client)
        if player.session != nil, player.errorMessage == nil {
            Router.shared.showNowPlaying()
        }
    }
}
