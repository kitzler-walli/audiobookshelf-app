import AbsWatchCore
import SwiftUI

/// Phase 0 spike tests (streaming buffer, sparse offline window, background downloads), kept for measurements.
/// Uses its own player and server session; stop the regular player first.
struct DebugView: View {
    private let model = SpikeModel.shared

    var body: some View {
        List {
            Section {
                Text("Spike tests use a separate player. Results go to the log.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Load continue listening") { Task { await model.loadItems() } }
                    .disabled(model.busy)
            }
            ForEach(model.items) { item in
                NavigationLink(item.title) { SpikeSessionView(item: item) }
            }
        }
        .navigationTitle("Debug")
        .task { await PlayerController.shared.stop() }
    }
}

struct SpikeSessionView: View {
    let item: LibraryItemSummary
    private let model = SpikeModel.shared

    var body: some View {
        @Bindable var model = model
        let player = model.player
        List {
            Section {
                Text(item.title).font(.headline).lineLimit(2)
                if model.session == nil {
                    Button("Start session") { Task { await model.open(item) } }
                        .disabled(model.busy)
                }
            }

            if model.session != nil {
                Section("Player") {
                    LabeledContent("Source", value: player.sourceDescription)
                    LabeledContent("Status", value: player.statusText)
                    LabeledContent("Position", value: SpikePlayer.format(player.bookTime))
                    LabeledContent("Buffered", value: "\(Int(player.bufferedAhead)) s")
                    HStack {
                        Button { player.skip(by: -30) } label: { Image(systemName: "gobackward.30") }
                        Button { player.isPlaying ? player.pause() : player.play() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        }
                        Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30") }
                    }
                    .buttonStyle(.borderless)
                }

                Section("1 · Stream") {
                    Button("Stream (default buffer)") { Task { await model.playStream(forwardBuffer: 0) } }
                    Button("Stream (10 min buffer)") { Task { await model.playStream(forwardBuffer: 600) } }
                }

                Section("2 · Offline window") {
                    Picker("Window", selection: $model.windowMinutes) {
                        Text("10 min").tag(10)
                        Text("1 h").tag(60)
                        Text("2 h").tag(120)
                    }
                    LabeledContent("From", value: SpikePlayer.format(model.windowStart))
                    LabeledContent("Downloaded", value: progressText)
                    LabeledContent("On disk", value: ByteCountFormatter.string(fromByteCount: model.allocatedBytes, countStyle: .file))
                    Button("Download (background)") { Task { await model.downloadWindow(inBackground: true) } }
                    Button("Download (foreground)") { Task { await model.downloadWindow(inBackground: false) } }
                    Button("Play local from start") { Task { await model.playLocal(fromWindowEnd: false) } }
                    Button("Play local near end") { Task { await model.playLocal(fromWindowEnd: true) } }
                    Button("Cancel downloads") { model.cancelDownloads() }
                    Button("Delete downloads", role: .destructive) { model.deleteDownloads() }
                }

                Section {
                    Button("Close session", role: .destructive) { Task { await model.closeSession() } }
                }
            }
        }
        .navigationTitle("Session")
    }

    private var progressText: String {
        guard model.plannedBytes > 0 else { return "–" }
        let percent = Int(Double(model.presentBytes) / Double(model.plannedBytes) * 100)
        return "\(percent) % of \(ByteCountFormatter.string(fromByteCount: model.plannedBytes, countStyle: .file))"
    }
}

struct LogView: View {
    var body: some View {
        List(Array(SpikeLog.shared.lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 11, design: .monospaced))
        }
        .navigationTitle("Log")
    }
}
