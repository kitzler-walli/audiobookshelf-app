import AbsWatchCore
import SwiftUI

/// What is stored on the watch, with sizes, and the download settings.
struct DownloadsView: View {
    private let downloads = DownloadManager.shared
    @State private var allowsCellular = DownloadManager.shared.allowsCellular
    @State private var confirmRemoveAll = false

    var body: some View {
        List {
            if downloads.items.isEmpty {
                Text("Nothing downloaded. Open a book and tap Download.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(downloads.items) { item in
                NavigationLink(value: Route.item(id: item.libraryItemId, episodeId: item.episodeId)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2)
                        DownloadStatusText(item: item)
                        Text(ByteCountFormatter.string(fromByteCount: downloads.allocatedBytes(item.id), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { downloads.remove(item.id) } label: { Label("Remove", systemImage: "trash") }
                }
            }

            Section {
                Toggle("Download over LTE", isOn: $allowsCellular)
                    .onChange(of: allowsCellular) { _, value in downloads.allowsCellular = value }
                if let free = downloads.freeBytes {
                    LabeledContent("Free", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                }
                if !downloads.items.isEmpty {
                    Button("Remove all", role: .destructive) { confirmRemoveAll = true }
                }
            } footer: {
                Text("Without LTE, downloads wait for Wi-Fi or the iPhone. \"Next\" downloads keep topping up while you listen.")
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Remove all downloads from this watch?", isPresented: $confirmRemoveAll) {
            Button("Remove all", role: .destructive) { downloads.removeAll() }
        }
    }
}
