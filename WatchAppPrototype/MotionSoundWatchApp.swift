import SwiftUI

@main
struct MotionSoundWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppLifecycleDelegate.self) private var appDelegate

    init() {
        AppDiagnostics.record("watch.app.init")
    }

    var body: some Scene {
        WindowGroup {
            MotionDebugView()
        }
    }
}
