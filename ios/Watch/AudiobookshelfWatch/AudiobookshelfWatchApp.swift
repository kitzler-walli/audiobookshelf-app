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

extension SpikeModel {
    /// Created once so the background URLSession is recreated with its identifier on every launch.
    static let shared = SpikeModel()
}

final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        // Covers are fetched often while browsing; keep them around
        URLCache.shared = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        _ = SpikeModel.shared
        PhoneLink.shared.activate()
        SpikeLog.shared.add("launched")
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask,
               urlTask.sessionIdentifier == RangeDownloader.backgroundIdentifier {
                SpikeLog.shared.add("woken for background downloads")
                SpikeModel.shared.background.backgroundEventsCompletion = {
                    urlTask.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
