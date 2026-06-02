import SwiftUI

@main
struct MotionSoundPhoneApp: App {
    init() {
        AppDiagnostics.record("phone.app.init")
    }

    var body: some Scene {
        WindowGroup {
            PhoneDebugView()
        }
    }
}
