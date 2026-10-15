import SwiftUI
import WatchKit

@main
struct AudiobookshelfWatchApp: App {
    @WKApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // Covers are fetched often while browsing; keep them around
        URLCache.shared = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        // Created at launch so the background URLSession is reconnected to its running downloads
        _ = DownloadManager.shared
        PhoneLink.shared.activate()
        AppLog.shared.add("launched")
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask,
               urlTask.sessionIdentifier == TrackDownloader.backgroundIdentifier {
                AppLog.shared.add("woken for background downloads")
                DownloadManager.shared.downloader.backgroundEventsCompletion = {
                    urlTask.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
