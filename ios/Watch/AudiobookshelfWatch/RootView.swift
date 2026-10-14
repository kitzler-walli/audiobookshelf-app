import AbsWatchCore
import SwiftUI

struct RootView: View {
    private let app = AppModel.shared
    @Bindable private var router = Router.shared

    var body: some View {
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
                        case .debug: DebugView()
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

    var body: some View {
        List {
            if player.session != nil {
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
            if items.isEmpty { loadError = error.localizedDescription }
        }
        loaded = true
    }
}
