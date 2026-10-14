import AbsWatchCore
import SwiftUI
import WatchKit

/// Own controls on the first page; the system Now Playing view (crown volume, audio route) on the second.
struct NowPlayingScreen: View {
    var body: some View {
        TabView {
            PlayerControlsPage()
            NowPlayingView()
        }
        .tabViewStyle(.verticalPage)
    }
}

private struct PlayerControlsPage: View {
    private let player = PlayerController.shared

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 1) {
                Text(player.currentChapter?.title ?? player.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(player.currentChapter != nil ? player.title : (player.author ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            chapterProgress

            HStack {
                Button { player.skip(by: -30) } label: { Image(systemName: "gobackward.30") }
                Button { player.togglePlayPause() } label: {
                    if player.isLoading || player.isBuffering {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    }
                }
                .tint(.orange)
                Button { player.skip(by: 30) } label: { Image(systemName: "goforward.30") }
            }
            .buttonStyle(.bordered)

            HStack {
                Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                Button { player.cycleRate() } label: { Text(rateText).font(.footnote.monospacedDigit()) }
                NavigationLink(value: Route.chapters) { Image(systemName: "list.bullet") }
                Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
            }
            .buttonStyle(.borderless)

            if let error = player.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .background {
            if let id = player.libraryItemId {
                CoverImage(libraryItemId: id, size: 200)
                    .blur(radius: 18)
                    .opacity(0.35)
                    .ignoresSafeArea()
            }
        }
        .overlay {
            if player.session == nil && !player.isLoading {
                Text("Nothing playing").foregroundStyle(.secondary)
            }
        }
    }

    /// Position within the current chapter (or the whole book without chapters).
    @ViewBuilder
    private var chapterProgress: some View {
        let start = player.currentChapter?.start ?? 0
        let end = player.currentChapter?.end ?? player.duration
        let elapsed = max(0, player.bookTime - start)
        let length = max(1, end - start)
        VStack(spacing: 1) {
            ProgressView(value: min(elapsed, length), total: length).tint(.orange)
            HStack {
                Text(PlayerController.format(elapsed))
                Spacer()
                Text("-" + PlayerController.format(max(0, length - elapsed)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var rateText: String {
        let rate = player.rate
        return rate == rate.rounded() ? String(format: "%.0f×", rate) : String(format: "%.2g×", rate)
    }
}

struct ChaptersView: View {
    private let player = PlayerController.shared

    var body: some View {
        ScrollViewReader { proxy in
            List(player.chapters) { chapter in
                Button {
                    player.seek(to: chapter.start)
                } label: {
                    HStack {
                        if chapter.id == player.currentChapter?.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.orange)
                        }
                        Text(chapter.title).font(.footnote).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(TimeText.duration(chapter.end - chapter.start)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .id(chapter.id)
            }
            .onAppear {
                if let current = player.currentChapter?.id { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .navigationTitle("Chapters")
    }
}
