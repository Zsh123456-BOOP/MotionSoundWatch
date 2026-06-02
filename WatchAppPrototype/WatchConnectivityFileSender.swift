import Foundation
import WatchConnectivity
import CryptoKit

@MainActor
final class WatchConnectivityFileSender: NSObject, ObservableObject {
    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var activationStateDescription = "not activated"
    @Published private(set) var lastTransferMessage: String?
    @Published private(set) var receivedSoundFiles: [URL] = []
    @Published private(set) var lastReceivedProfileURL: URL?
    @Published private(set) var lastRecordingCommand: RecordingControlCommand?

    private var session: WCSession? {
        isSupported ? WCSession.default : nil
    }

    private let fileManager = FileManager.default

    override init() {
        super.init()
        AppDiagnostics.record("watch.connectivity.init", ["supported": isSupported])
        reloadReceivedSoundFiles()
    }

    func activate() {
        guard let session else {
            lastTransferMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("watch.connectivity.activate.unsupported")
            return
        }
        guard session.delegate == nil || session.delegate === self else {
            session.delegate = self
            session.activate()
            AppDiagnostics.record("watch.connectivity.activate.reassignDelegate")
            return
        }

        session.delegate = self
        session.activate()
        activationStateDescription = description(for: session.activationState)
        AppDiagnostics.record("watch.connectivity.activate", ["state": activationStateDescription])
    }

    @discardableResult
    func transferFile(_ fileURL: URL, kind: SyncedFileKind) -> Bool {
        guard let session else {
            lastTransferMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("watch.connectivity.transfer.unsupported", ["kind": kind.rawValue])
            return false
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            lastTransferMessage = "文件不存在：\(fileURL.lastPathComponent)"
            AppDiagnostics.record("watch.connectivity.transfer.missingFile", ["file": fileURL.lastPathComponent, "kind": kind.rawValue])
            return false
        }

        let metadata: [String: Any] = [
            "kind": kind.rawValue,
            "fileName": fileURL.lastPathComponent,
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundWatch",
        ]
        session.transferFile(fileURL, metadata: metadata)
        lastTransferMessage = "已加入发送队列：\(fileURL.lastPathComponent)"
        AppDiagnostics.record("watch.connectivity.transfer.queued", ["file": fileURL.lastPathComponent, "kind": kind.rawValue])
        return true
    }

    @discardableResult
    func sendRecordingStatus(
        action: RecordingControlAction,
        label: String,
        state: String,
        samples: Int,
        csvQueued: Bool = false,
        fileName: String? = nil,
        errorMessage: String? = nil
    ) -> Bool {
        guard let session else {
            lastTransferMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("watch.connectivity.status.unsupported")
            return false
        }

        var message: [String: Any] = [
            "command": "recordingStatus",
            "action": action.rawValue,
            "label": label,
            "state": state,
            "samples": samples,
            "csvQueued": csvQueued,
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundWatch",
        ]
        if let fileName, !fileName.isEmpty {
            message["fileName"] = fileName
        }
        if let errorMessage, !errorMessage.isEmpty {
            message["errorMessage"] = errorMessage
        }

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [weak self] error in
                Task { @MainActor in
                    self?.lastTransferMessage = error.localizedDescription
                    AppDiagnostics.record(error: error, event: "watch.connectivity.status.sendMessage.error")
                }
            }
            AppDiagnostics.record("watch.connectivity.status.sent", ["action": action.rawValue, "samples": samples])
            return true
        }

        session.transferUserInfo(message)
        lastTransferMessage = "已加入录制状态队列"
        AppDiagnostics.record("watch.connectivity.status.queued", ["action": action.rawValue, "samples": samples])
        return true
    }

    func reloadReceivedSoundFiles() {
        do {
            let directory = try WatchSoundPlayer.soundsDirectory()
            guard fileManager.fileExists(atPath: directory.path) else {
                receivedSoundFiles = []
                return
            }

            receivedSoundFiles = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { Self.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                modificationDate(lhs) > modificationDate(rhs)
            }
            AppDiagnostics.record("watch.audioFiles.reload", ["count": receivedSoundFiles.count])
        } catch {
            lastTransferMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.audioFiles.reload.error")
        }
    }

    private func receiveAudio(fileURL: URL, preferredFileName: String?, checksum: String?) {
        do {
            let directory = try WatchSoundPlayer.soundsDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let preferredName = preferredFileName?.isEmpty == false
                ? preferredFileName!
                : fileURL.lastPathComponent
            let destination = availableDestinationURL(
                directory: directory,
                fileName: sanitizeFileName(preferredName)
            )

            if let checksum, let actualChecksum = sha256Hex(fileURL), checksum != actualChecksum {
                lastTransferMessage = "音频校验失败：\(preferredName)"
                AppDiagnostics.record("watch.connectivity.receiveAudio.checksumMismatch", ["file": preferredName])
                return
            }

            try fileManager.moveItem(at: fileURL, to: destination)
            reloadReceivedSoundFiles()
            lastTransferMessage = "已接收音频：\(destination.lastPathComponent)"
            AppDiagnostics.record("watch.connectivity.receiveAudio", ["file": destination.lastPathComponent])
        } catch {
            lastTransferMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.connectivity.receiveAudio.error", ["file": preferredFileName ?? fileURL.lastPathComponent])
        }
    }

    private func receiveProfile(fileURL: URL, preferredFileName: String?, checksum: String?) {
        do {
            if let checksum, let actualChecksum = sha256Hex(fileURL), checksum != actualChecksum {
                lastTransferMessage = "Profile 校验失败：\(preferredFileName ?? fileURL.lastPathComponent)"
                AppDiagnostics.record("watch.connectivity.receiveProfile.checksumMismatch", ["file": preferredFileName ?? fileURL.lastPathComponent])
                return
            }

            let data = try Data(contentsOf: fileURL)
            _ = try GestureProfileCodec().decode(data)

            let store = try GestureProfileFileStore.appDocumentsStore()
            try fileManager.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)

            let preferredName = preferredFileName?.isEmpty == false
                ? preferredFileName!
                : fileURL.lastPathComponent
            let destination = availableDestinationURL(
                directory: store.directoryURL,
                fileName: sanitizeProfileFileName(preferredName)
            )
            try fileManager.moveItem(at: fileURL, to: destination)
            lastReceivedProfileURL = destination
            lastTransferMessage = "已接收 Profile：\(destination.lastPathComponent)"
            AppDiagnostics.record("watch.connectivity.receiveProfile", ["file": destination.lastPathComponent])
        } catch {
            lastTransferMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.connectivity.receiveProfile.error", ["file": preferredFileName ?? fileURL.lastPathComponent])
        }
    }

    private func receiveRecordingCommand(
        action: String?,
        label: String?,
        kind: String?,
        sampleRole: String?,
        autoSendCSV: Bool?
    ) {
        guard let action = RecordingControlAction(rawValue: action ?? "") else {
            lastTransferMessage = "忽略未知录制命令"
            AppDiagnostics.record("watch.connectivity.recordingCommand.unknown", ["action": action ?? ""])
            return
        }

        let command = RecordingControlCommand(
            action: action,
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines),
            kindRawValue: kind,
            sampleRole: sampleRole,
            autoSendCSV: autoSendCSV ?? false
        )
        lastRecordingCommand = command
        switch action {
        case .startRecording:
            lastTransferMessage = "收到手机开始录制命令"
        case .stopRecording:
            lastTransferMessage = "收到手机停止录制命令"
        }
        AppDiagnostics.record(
            "watch.connectivity.recordingCommand.received",
            [
                "action": action.rawValue,
                "label": command.label ?? "",
                "kind": command.kindRawValue ?? "",
                "sampleRole": command.sampleRole ?? "",
                "autoSendCSV": command.autoSendCSV,
            ]
        )
    }

    private func description(for state: WCSessionActivationState) -> String {
        switch state {
        case .activated:
            return "activated"
        case .inactive:
            return "inactive"
        case .notActivated:
            return "not activated"
        @unknown default:
            return "unknown"
        }
    }

    private func availableDestinationURL(directory: URL, fileName: String) -> URL {
        var destination = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: destination.path) else {
            return destination
        }

        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        let timestamp = Int(Date().timeIntervalSince1970)
        destination = directory.appendingPathComponent("\(base)-\(timestamp).\(ext)")
        return destination
    }

    private func sanitizeFileName(_ value: String) -> String {
        let fallback = "sound"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return compact.isEmpty ? fallback : compact
    }

    private func sanitizeProfileFileName(_ value: String) -> String {
        var fileName = sanitizeFileName(value)
        if fileName.lowercased().hasSuffix(".json") {
            return fileName
        }
        fileName += ".json"
        return fileName
    }

    private func modificationDate(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }

    private func sha256Hex(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let supportedAudioExtensions = ["wav", "mp3", "m4a", "aac", "caf", "aiff", "aif"]
}

enum SyncedFileKind: String {
    case recordingCSV
    case gestureProfile
    case audioAsset
}

enum RecordingControlAction: String, Equatable {
    case startRecording
    case stopRecording
}

struct RecordingControlCommand: Identifiable, Equatable {
    let id = UUID()
    var action: RecordingControlAction
    var label: String?
    var kindRawValue: String?
    var sampleRole: String?
    var autoSendCSV: Bool
}

extension WatchConnectivityFileSender: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            activationStateDescription = description(for: activationState)
            if let error {
                lastTransferMessage = error.localizedDescription
                AppDiagnostics.record(error: error, event: "watch.connectivity.activation.error")
            } else {
                AppDiagnostics.record("watch.connectivity.activation", ["state": activationStateDescription])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fileURL = file.fileURL
        let kind = file.metadata?["kind"] as? String
        let preferredFileName = file.metadata?["fileName"] as? String
        let checksum = file.metadata?["checksum"] as? String
        Task { @MainActor in
            switch kind {
            case SyncedFileKind.audioAsset.rawValue:
                receiveAudio(fileURL: fileURL, preferredFileName: preferredFileName, checksum: checksum)
            case SyncedFileKind.gestureProfile.rawValue:
                receiveProfile(fileURL: fileURL, preferredFileName: preferredFileName, checksum: checksum)
            default:
                lastTransferMessage = "忽略未知文件：\(preferredFileName ?? fileURL.lastPathComponent)"
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let command = message["command"] as? String
        let action = message["action"] as? String
        let label = message["label"] as? String
        let kind = message["kind"] as? String
        let sampleRole = message["sampleRole"] as? String
        let autoSendCSV = message["autoSendCSV"] as? Bool
        Task { @MainActor in
            guard command == "recordingControl" else { return }
            receiveRecordingCommand(
                action: action,
                label: label,
                kind: kind,
                sampleRole: sampleRole,
                autoSendCSV: autoSendCSV
            )
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let command = message["command"] as? String
        let action = message["action"] as? String
        let label = message["label"] as? String
        let kind = message["kind"] as? String
        let sampleRole = message["sampleRole"] as? String
        let autoSendCSV = message["autoSendCSV"] as? Bool

        guard command == "recordingControl",
              RecordingControlAction(rawValue: action ?? "") != nil else {
            replyHandler([
                "status": "rejected",
                "reason": "unknownRecordingCommand",
                "receivedAt": Date().timeIntervalSince1970,
            ])
            return
        }

        replyHandler([
            "status": "accepted",
            "action": action ?? "",
            "receivedAt": Date().timeIntervalSince1970,
        ])

        Task { @MainActor in
            receiveRecordingCommand(
                action: action,
                label: label,
                kind: kind,
                sampleRole: sampleRole,
                autoSendCSV: autoSendCSV
            )
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let command = userInfo["command"] as? String
        let action = userInfo["action"] as? String
        let label = userInfo["label"] as? String
        let kind = userInfo["kind"] as? String
        let sampleRole = userInfo["sampleRole"] as? String
        let autoSendCSV = userInfo["autoSendCSV"] as? Bool
        Task { @MainActor in
            guard command == "recordingControl" else { return }
            receiveRecordingCommand(
                action: action,
                label: label,
                kind: kind,
                sampleRole: sampleRole,
                autoSendCSV: autoSendCSV
            )
        }
    }
}
