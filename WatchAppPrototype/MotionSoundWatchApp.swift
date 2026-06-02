import SwiftUI

@main
struct MotionSoundWatchApp: App {
    init() {
        AppDiagnostics.record("watch.app.init")
    }

    var body: some Scene {
        WindowGroup {
            MotionDebugView()
        }
    }
}
