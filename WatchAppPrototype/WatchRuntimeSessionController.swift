import Foundation
import WatchKit

@MainActor
final class WatchRuntimeSessionController: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "待命"

    private var session: WKExtendedRuntimeSession?

    func start(reason: String) {
        guard session?.state != .running else {
            AppDiagnostics.record("watch.runtime.start.skipped", ["reason": reason, "state": "running"])
            return
        }

        if let existing = session, existing.state != .invalid {
            existing.invalidate()
        }

        let nextSession = WKExtendedRuntimeSession()
        nextSession.delegate = self
        session = nextSession
        statusText = "保持监听"
        AppDiagnostics.record("watch.runtime.start.requested", ["reason": reason])
        nextSession.start()
    }

    func stop(reason: String) {
        guard let session else { return }
        AppDiagnostics.record("watch.runtime.stop.requested", ["reason": reason, "state": Self.describe(session.state)])
        session.invalidate()
    }

    private func handleStarted(expiresAt: TimeInterval) {
        isRunning = true
        statusText = "保持监听"
        AppDiagnostics.record("watch.runtime.started", ["expiresAt": expiresAt])
    }

    private func handleWillExpire() {
        statusText = "监听即将结束"
        AppDiagnostics.record("watch.runtime.willExpire")
    }

    private func handleInvalidated(
        reason: WKExtendedRuntimeSessionInvalidationReason,
        errorMessage: String?
    ) {
        isRunning = false
        statusText = "监听已暂停"
        session = nil

        var fields: [String: CustomStringConvertible] = [
            "reason": Self.describe(reason),
        ]
        if let errorMessage {
            fields["error"] = errorMessage
        }
        AppDiagnostics.record("watch.runtime.invalidated", fields)
    }

    nonisolated private static func describe(_ state: WKExtendedRuntimeSessionState) -> String {
        switch state {
        case .notStarted:
            return "notStarted"
        case .scheduled:
            return "scheduled"
        case .running:
            return "running"
        case .invalid:
            return "invalid"
        @unknown default:
            return "unknown"
        }
    }

    nonisolated private static func describe(_ reason: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch reason {
        case .none:
            return "none"
        case .sessionInProgress:
            return "sessionInProgress"
        case .expired:
            return "expired"
        case .resignedFrontmost:
            return "resignedFrontmost"
        case .suppressedBySystem:
            return "suppressedBySystem"
        case .error:
            return "error"
        @unknown default:
            return "unknown"
        }
    }
}

extension WatchRuntimeSessionController: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let expiresAt = extendedRuntimeSession.expirationDate?.timeIntervalSince1970 ?? 0
        Task { @MainActor in
            handleStarted(expiresAt: expiresAt)
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            handleWillExpire()
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let errorMessage = error?.localizedDescription
        Task { @MainActor in
            handleInvalidated(reason: reason, errorMessage: errorMessage)
        }
    }
}
