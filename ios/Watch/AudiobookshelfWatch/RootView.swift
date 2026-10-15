import AbsWatchCore
import SwiftUI

struct RootView: View {
    private let app = AppModel.shared
    @Bindable private var router = Router.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                DownloadManager.shared.appStateChanged(isActive: phase == .active)
                guard phase == .active, app.isPaired else { return }
                Task {
                    await app.uploadPendingSessions()
                    await DownloadManager.shared.resumeAll()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if app.isPaired {
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .item(let id, let episodeId): ItemDetailView(libraryItemId: id, episodeId: episodeId)
                        case .libraries: LibrariesView()
                        case .library(let library): LibraryItemsView(library: library)
                        case .nowPlaying: NowPlayingScreen()
                        case .chapters: ChaptersView()
                        case .settings: SettingsView()
                        case .downloads: DownloadsView()
                        case .log: LogView()
                        }
                    }
            }
        } else {
            PairingView()
        }
    }
}

struct PairingView: View {
    private let app = AppModel.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "headphones")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Connect this watch to your server through the Audiobookshelf app on your iPhone. You only need the iPhone once.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Pair with iPhone") { Task { await app.pair() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(app.isPairing)
                if let status = app.pairingStatus {
                    Text(status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Audiobookshelf")
    }
}

struct HomeView: View {
    @State private var items: [LibraryItemSummary] = []
    @State private var progress: [String: MediaProgress] = [:]
    @State private var loaded = false
    @State private var loadError: String?
    private let player = PlayerController.shared
    private let downloads = DownloadManager.shared

    var body: some View {
        List {
            if player.isActive {
                Section {
                    NavigationLink(value: Route.nowPlaying) { NowPlayingRow() }
                }
            }

            Section("Continue listening") {
                if !loaded {
                    ProgressView()
                } else if items.isEmpty {
                    Text(loadError ?? "Nothing in progress").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    NavigationLink(value: Route.item(id: item.id, episodeId: item.recentEpisode?.id)) {
                        ItemRow(item: item, progress: progress[item.progressKey])
                    }
                }
            }

            if !downloads.items.isEmpty {
                Section("On this watch") {
                    ForEach(downloads.items) { item in
                        NavigationLink(value: Route.item(id: item.libraryItemId, episodeId: item.episodeId)) {
                            DownloadedRow(item: item)
                        }
                    }
                }
            }

            Section {
                NavigationLink(value: Route.libraries) { Label("Libraries", systemImage: "books.vertical") }
                NavigationLink(value: Route.settings) { Label("Settings", systemImage: "gearshape") }
            }
        }
        .navigationTitle("Audiobookshelf")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = AppModel.shared.client else { return }
        do {
            async let inProgress = client.itemsInProgress()
            async let allProgress = client.allMediaProgress()
            items = try await inProgress
            progress = Dictionary(try await allProgress.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            loadError = nil
        } catch {
            AppModel.shared.handle(error)
            if items.isEmpty { loadError = Self.describe(error) }
        }
        loaded = true
    }

    /// Offline is normal on a walk; say so instead of showing a URL error.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dataNotAllowed].contains(urlError.code) {
            return "Offline. Downloaded books are below."
        }
        return error.localizedDescription
    }
}

struct DownloadedRow: View {
    let item: DownloadedItem

    var body: some View {
        HStack(spacing: 8) {
            CoverImage(libraryItemId: item.libraryItemId)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2)
                if let position = item.position, position > 0 {
                    ProgressView(value: min(1, position / max(1, item.duration))).tint(.orange)
                }
                DownloadStatusText(item: item)
            }
        }
    }
}
