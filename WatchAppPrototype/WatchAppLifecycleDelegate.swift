import Foundation
import WatchKit

extension Notification.Name {
    static let watchApplicationDidBecomeActive = Notification.Name("MotionSoundWatchApplicationDidBecomeActive")
    static let watchApplicationWillResignActive = Notification.Name("MotionSoundWatchApplicationWillResignActive")
}

final class WatchAppLifecycleDelegate: NSObject, WKApplicationDelegate {
    func applicationDidBecomeActive() {
        AppDiagnostics.record("watch.lifecycle.didBecomeActive")
        NotificationCenter.default.post(name: .watchApplicationDidBecomeActive, object: nil)
    }

    func applicationWillResignActive() {
        AppDiagnostics.record("watch.lifecycle.willResignActive")
        NotificationCenter.default.post(name: .watchApplicationWillResignActive, object: nil)
    }
}
