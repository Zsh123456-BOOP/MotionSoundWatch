import Foundation
import WatchConnectivity
import CryptoKit

struct ReceivedSyncedFile: Identifiable, Equatable {
    var id: URL { fileURL }
    var fileURL: URL
    var kind: String
    var receivedAt: Date
}

struct RecordingStatusEvent: Identifiable, Equatable {
    let id = UUID()
    var actionRawValue: String
    var label: String
    var state: String
    var samples: Int
    var csvQueued: Bool
    var fileName: String?
    var errorMessage: String?
    var receivedAt: Date
}

@MainActor
final class PhoneConnectivityReceiver: NSObject, ObservableObject {
    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var activationStateDescription = "not activated"
    @Published private(set) var isWatchReachable = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var receivedFiles: [ReceivedSyncedFile] = []
    @Published private(set) var lastMessage: String?
    @Published private(set) var lastRecordingStatus: RecordingStatusEvent?

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        super.init()
        AppDiagnostics.record("phone.connectivity.init", ["supported": isSupported])
        reloadReceivedFiles()
    }

    private var session: WCSession? {
        isSupported ? WCSession.default : nil
    }

    func activate() {
        guard let session else {
            lastMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("phone.connectivity.activate.unsupported")
            return
        }

        session.delegate = self
        session.activate()
        refreshSessionState(
            activationState: session.activationState,
            isReachable: session.isReachable,
            isWatchAppInstalled: session.isWatchAppInstalled
        )
        AppDiagnostics.record(
            "phone.connectivity.activate",
            [
                "state": activationStateDescription,
                "reachable": isWatchReachable,
                "watchAppInstalled": isWatchAppInstalled,
            ]
        )
    }

    func reloadReceivedFiles() {
        do {
            let directory = try incomingDirectory()
            guard fileManager.fileExists(atPath: directory.path) else {
                receivedFiles = []
                return
            }

            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            receivedFiles = urls
                .filter { ["csv", "json"].contains($0.pathExtension.lowercased()) }
                .map { url in
                    ReceivedSyncedFile(
                        fileURL: url,
                        kind: kind(from: url),
                        receivedAt: modificationDate(url)
                    )
                }
                .sorted { $0.receivedAt > $1.receivedAt }
            AppDiagnostics.record("phone.files.reloadReceived", ["count": receivedFiles.count])
        } catch {
            lastMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.files.reloadReceived.error")
        }
    }

    func setLastMessage(_ message: String) {
        lastMessage = message
    }

    @discardableResult
    func sendRecordingCommand(
        action: RecordingControlAction,
        label: String,
        kind: String,
        sampleRole: String,
        autoSendCSV: Bool = false
    ) -> Bool {
        guard let session else {
            lastMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("phone.recordingCommand.unsupported", ["action": action.rawValue])
            return false
        }

        let message: [String: Any] = [
            "command": "recordingControl",
            "action": action.rawValue,
            "label": label.trimmingCharacters(in: .whitespacesAndNewlines),
            "kind": kind,
            "sampleRole": sampleRole,
            "autoSendCSV": autoSendCSV,
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundPhone",
        ]

        if session.isReachable {
            session.sendMessage(message) { [weak self] reply in
                let status = reply["status"] as? String
                let action = reply["action"] as? String
                let samples = reply["samples"] as? Int
                Task { @MainActor in
                    AppDiagnostics.record(
                        "phone.recordingCommand.reply",
                        [
                            "status": status ?? "",
                            "action": action ?? "",
                            "samples": samples ?? -1,
                        ]
                    )
                    if status == "accepted" {
                        if action == RecordingControlAction.startRecording.rawValue {
                            self?.lastMessage = "Watch 已确认开始录制"
                        } else if let samples {
                            self?.lastMessage = "Watch 已确认停止录制，样本 \(samples)"
                        } else {
                            self?.lastMessage = "Watch 已确认停止录制"
                        }
                    } else {
                        self?.lastMessage = "Watch 回执异常"
                    }
                }
            } errorHandler: { [weak self] error in
                let message = error.localizedDescription
                Task { @MainActor in
                    self?.lastMessage = message
                    AppDiagnostics.record(error: error, event: "phone.recordingCommand.sendMessage.error", ["action": action.rawValue])
                }
            }
            lastMessage = action == .startRecording ? "已发送开始录制命令" : "已发送停止录制命令"
            refreshSessionState(
                activationState: session.activationState,
                isReachable: session.isReachable,
                isWatchAppInstalled: session.isWatchAppInstalled
            )
            AppDiagnostics.record(
                "phone.recordingCommand.sent",
                [
                    "action": action.rawValue,
                    "label": label,
                    "kind": kind,
                    "sampleRole": sampleRole,
                    "autoSendCSV": autoSendCSV,
                    "reachable": true,
                ]
            )
            return true
        }

        session.transferUserInfo(message)
        lastMessage = "Watch 暂不可达，已加入录制命令队列"
        refreshSessionState(
            activationState: session.activationState,
            isReachable: session.isReachable,
            isWatchAppInstalled: session.isWatchAppInstalled
        )
        AppDiagnostics.record(
            "phone.recordingCommand.queued",
            [
                "action": action.rawValue,
                "label": label,
                "kind": kind,
                "sampleRole": sampleRole,
                "autoSendCSV": autoSendCSV,
                "reachable": false,
            ]
        )
        return true
    }

    @discardableResult
    func sendAudioFile(_ sourceURL: URL) -> Bool {
        sendFile(sourceURL, kind: .audioAsset, queuedMessagePrefix: "已加入音频发送队列")
    }

    @discardableResult
    func sendProfileFile(_ sourceURL: URL) -> Bool {
        sendFile(sourceURL, kind: .gestureProfile, queuedMessagePrefix: "已加入 Profile 发送队列")
    }

    @discardableResult
    func generateAndSendProfile(
        gesture: String,
        kind kindRawValue: String,
        soundFileName: String? = nil,
        primarySamplesOverride: [MotionSample]? = nil
    ) -> Bool {
        let trimmedGesture = gesture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGesture.isEmpty else {
            lastMessage = "动作名称为空"
            return false
        }
        guard let kind = GestureKind(rawValue: kindRawValue) else {
            lastMessage = "动作类型无效：\(kindRawValue)"
            return false
        }

        do {
            let csvFiles = receivedFiles
                .filter { $0.fileURL.pathExtension.lowercased() == "csv" }
                .filter { Self.parseCaptureFileName($0.fileURL.deletingPathExtension().lastPathComponent).gesture == trimmedGesture }

            var positiveTemplates: [MotionTemplate] = []
            var negativeTemplates: [MotionTemplate] = []
            let csvCodec = MotionSampleCSVCodec()
            let templateBuilder = MotionTemplateBuilder()

            if let primarySamplesOverride, !primarySamplesOverride.isEmpty {
                positiveTemplates.append(templateBuilder.makeTemplate(
                    label: trimmedGesture,
                    kind: kind,
                    samples: primarySamplesOverride
                ))
                AppDiagnostics.record(
                    "phone.profile.primarySamplesOverride",
                    [
                        "gesture": trimmedGesture,
                        "samples": primarySamplesOverride.count,
                    ]
                )
            }

            for file in csvFiles {
                let parsed = Self.parseCaptureFileName(file.fileURL.deletingPathExtension().lastPathComponent)
                let samples = try csvCodec.decodeData(Data(contentsOf: file.fileURL))
                guard !samples.isEmpty else { continue }

                switch parsed.role {
                case "positive":
                    if primarySamplesOverride == nil {
                        positiveTemplates.append(templateBuilder.makeTemplate(
                            label: trimmedGesture,
                            kind: kind,
                            samples: samples
                        ))
                    }
                case "negative":
                    negativeTemplates.append(templateBuilder.makeTemplate(
                        label: "\(trimmedGesture)-negative",
                        kind: kind,
                        samples: samples
                    ))
                default:
                    continue
                }
            }

            guard !positiveTemplates.isEmpty else {
                lastMessage = "没有可生成 Profile 的正样本：\(trimmedGesture)"
                return false
            }

            let sound = normalizedSoundAsset(fileName: soundFileName)
            let profile = GestureProfileBuilder().makeProfile(
                name: trimmedGesture,
                kind: kind,
                templates: positiveTemplates,
                negativeTemplates: negativeTemplates,
                sound: sound
            )
            let archive = GestureProfileArchive(profiles: [profile])
            let data = try GestureProfileCodec().encode(archive)
            let url = try writeGeneratedProfile(data, gesture: trimmedGesture)
            lastMessage = "已生成 Profile：\(url.lastPathComponent)"
            return sendProfileFile(url)
        } catch {
            lastMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func sendFile(_ sourceURL: URL, kind: SyncedFileKind, queuedMessagePrefix: String) -> Bool {
        guard let session else {
            lastMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("phone.connectivity.transfer.unsupported", ["kind": kind.rawValue])
            return false
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let fileURL = try copyToOutgoingDirectory(sourceURL)
            let metadata: [String: Any] = [
                "kind": kind.rawValue,
                "fileName": fileURL.lastPathComponent,
                "sentAt": Date().timeIntervalSince1970,
                "source": "MotionSoundPhone",
                "checksum": try sha256Hex(fileURL),
            ]
            session.transferFile(fileURL, metadata: metadata)
            lastMessage = "\(queuedMessagePrefix)：\(fileURL.lastPathComponent)"
            AppDiagnostics.record("phone.connectivity.transfer.queued", ["file": fileURL.lastPathComponent, "kind": kind.rawValue])
            return true
        } catch {
            lastMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.connectivity.transfer.error", ["file": sourceURL.lastPathComponent, "kind": kind.rawValue])
            return false
        }
    }

    private func receive(fileURL: URL, preferredFileName: String?) {
        do {
            let directory = try incomingDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let preferredName = preferredFileName?.isEmpty == false
                ? preferredFileName!
                : fileURL.lastPathComponent
            let destination = availableDestinationURL(
                directory: directory,
                fileName: sanitizeFileName(preferredName)
            )

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: fileURL, to: destination)
            lastMessage = "已接收：\(destination.lastPathComponent)"
            AppDiagnostics.record("phone.connectivity.receiveFile", ["file": destination.lastPathComponent])
            reloadReceivedFiles()
        } catch {
            lastMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.connectivity.receiveFile.error", ["file": preferredFileName ?? fileURL.lastPathComponent])
        }
    }

    private func receiveRecordingStatus(
        command: String?,
        action: String?,
        label: String?,
        state: String?,
        samples: Int,
        csvQueued: Bool,
        fileName: String?,
        errorMessage: String?
    ) {
        guard command == "recordingStatus" else { return }

        let event = RecordingStatusEvent(
            actionRawValue: action ?? "",
            label: label ?? "",
            state: state ?? "",
            samples: samples,
            csvQueued: csvQueued,
            fileName: fileName,
            errorMessage: errorMessage,
            receivedAt: Date()
        )
        lastRecordingStatus = event
        lastMessage = Self.message(for: event)
        AppDiagnostics.record(
            "phone.recordingStatus.received",
            [
                "action": event.actionRawValue,
                "label": event.label,
                "state": event.state,
                "samples": event.samples,
                "csvQueued": event.csvQueued,
                "file": event.fileName ?? "",
                "error": event.errorMessage ?? "",
            ]
        )
    }

    private func incomingDirectory() throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("MotionSoundIncoming", isDirectory: true)
    }

    private func outgoingDirectory() throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("MotionSoundOutgoing", isDirectory: true)
    }

    private func copyToOutgoingDirectory(_ sourceURL: URL) throws -> URL {
        let directory = try outgoingDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = availableDestinationURL(
            directory: directory,
            fileName: sanitizeFileName(sourceURL.lastPathComponent)
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func writeGeneratedProfile(_ data: Data, gesture: String) throws -> URL {
        let directory = try outgoingDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(fileTimestamp(Date()))-\(sanitizeFileName(gesture))-profile.json"
        let destination = availableDestinationURL(directory: directory, fileName: fileName)
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    private func normalizedSoundAsset(fileName: String?) -> SoundAsset? {
        guard let fileName else { return nil }
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SoundAsset(fileName: trimmed, duration: 0, localWatchPath: trimmed)
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
        let fallback = "motion-sound-file"
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

    private func kind(from url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "csv":
            return "recordingCSV"
        case "json":
            return "gestureProfile"
        default:
            return "unknown"
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }

    private func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func refreshSessionState(
        activationState: WCSessionActivationState,
        isReachable: Bool,
        isWatchAppInstalled: Bool
    ) {
        activationStateDescription = Self.description(for: activationState)
        isWatchReachable = isReachable
        self.isWatchAppInstalled = isWatchAppInstalled
    }

    private static func description(for state: WCSessionActivationState) -> String {
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

    private static func message(for event: RecordingStatusEvent) -> String {
        if let errorMessage = event.errorMessage, !errorMessage.isEmpty {
            return "Watch 执行失败：\(errorMessage)"
        }

        let label = event.label.isEmpty ? "未命名动作" : event.label
        if event.actionRawValue == RecordingControlAction.startRecording.rawValue {
            return "Watch 正在录制：\(label)"
        }

        if event.csvQueued {
            let suffix = event.fileName.map { "，CSV \($0)" } ?? "，CSV 已排队"
            return "Watch 已停止，样本 \(event.samples)\(suffix)"
        }

        return "Watch 已停止，样本 \(event.samples)"
    }

    nonisolated static func parseCaptureFileName(_ fileName: String) -> (gesture: String, role: String) {
        let parts = fileName
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }

        let roleIndex = parts.firstIndex { part in
            ["positive", "negative", "debug"].contains(part.lowercased())
        }
        let role = roleIndex.map { parts[$0].lowercased() } ?? "unknown"
        let startIndex = min(2, parts.count)
        let endIndex = roleIndex.map { max(startIndex, $0) } ?? parts.count
        let gesture = parts[startIndex..<endIndex].joined(separator: "-")
        return (gesture.isEmpty ? "unknown" : gesture, role)
    }
}

enum SyncedFileKind: String {
    case recordingCSV
    case gestureProfile
    case audioAsset
}

enum RecordingControlAction: String {
    case startRecording
    case stopRecording
}

extension PhoneConnectivityReceiver: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let isReachable = session.isReachable
        let isWatchAppInstalled = session.isWatchAppInstalled
        Task { @MainActor in
            refreshSessionState(
                activationState: activationState,
                isReachable: isReachable,
                isWatchAppInstalled: isWatchAppInstalled
            )
            if let error {
                lastMessage = error.localizedDescription
                AppDiagnostics.record(error: error, event: "phone.connectivity.activation.error")
            } else {
                AppDiagnostics.record(
                    "phone.connectivity.activation",
                    [
                        "state": activationStateDescription,
                        "reachable": isWatchReachable,
                        "watchAppInstalled": isWatchAppInstalled,
                    ]
                )
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fileURL = file.fileURL
        let preferredFileName = file.metadata?["fileName"] as? String
        Task { @MainActor in
            receive(fileURL: fileURL, preferredFileName: preferredFileName)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let command = message["command"] as? String
        let action = message["action"] as? String
        let label = message["label"] as? String
        let state = message["state"] as? String
        let samples = message["samples"] as? Int ?? 0
        let csvQueued = message["csvQueued"] as? Bool ?? false
        let fileName = message["fileName"] as? String
        let errorMessage = message["errorMessage"] as? String
        Task { @MainActor in
            receiveRecordingStatus(
                command: command,
                action: action,
                label: label,
                state: state,
                samples: samples,
                csvQueued: csvQueued,
                fileName: fileName,
                errorMessage: errorMessage
            )
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let command = userInfo["command"] as? String
        let action = userInfo["action"] as? String
        let label = userInfo["label"] as? String
        let state = userInfo["state"] as? String
        let samples = userInfo["samples"] as? Int ?? 0
        let csvQueued = userInfo["csvQueued"] as? Bool ?? false
        let fileName = userInfo["fileName"] as? String
        let errorMessage = userInfo["errorMessage"] as? String
        Task { @MainActor in
            receiveRecordingStatus(
                command: command,
                action: action,
                label: label,
                state: state,
                samples: samples,
                csvQueued: csvQueued,
                fileName: fileName,
                errorMessage: errorMessage
            )
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let activationState = session.activationState
        let isReachable = session.isReachable
        let isWatchAppInstalled = session.isWatchAppInstalled
        Task { @MainActor in
            refreshSessionState(
                activationState: activationState,
                isReachable: isReachable,
                isWatchAppInstalled: isWatchAppInstalled
            )
        }
    }
}
