import Foundation
import WatchConnectivity
import CryptoKit

@MainActor
final class WatchConnectivityFileSender: NSObject, ObservableObject {
    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var activationStateDescription = "not activated"
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var lastTransferMessage: String?
    @Published private(set) var receivedSoundFiles: [URL] = []
    @Published private(set) var lastReceivedProfileURL: URL?
    @Published private(set) var lastRecordingCommand: RecordingControlCommand?
    @Published private(set) var runtimePrepareRequestCount = 0
    @Published private(set) var profileLibraryChangeCount = 0
    @Published private(set) var profileLibraryStateChangeCount = 0
    @Published private(set) var profileLibraryVersion: String?
    @Published private(set) var profileLibraryProfileCount = 0
    @Published private(set) var isProfileLibraryReady = false
    @Published private(set) var recognitionEventSyncCount = 0
    @Published private(set) var lastProfileSyncTransactionID: UUID?
    @Published private(set) var missingProfileAudioFileNames: [String] = []

    private var session: WCSession? {
        isSupported ? WCSession.default : nil
    }

    private let fileManager = FileManager.default
    private var pendingProfileManifest: ProfileSyncManifest?

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
        isPhoneReachable = session.isReachable
        AppDiagnostics.record(
            "watch.connectivity.activate",
            [
                "state": activationStateDescription,
                "reachable": isPhoneReachable,
            ]
        )
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
            WatchRecordingStatusTransport.send(session: session, message: message) { [weak self] errorMessage in
                self?.lastTransferMessage = errorMessage
                AppDiagnostics.record(
                    "watch.connectivity.status.sendMessage.error",
                    ["error": errorMessage]
                )
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

    @discardableResult
    func sendPlaySound(fileName: String, profileName: String, volume: Float) -> Bool {
        guard let session else {
            lastTransferMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("watch.playSound.unsupported", ["file": fileName, "profile": profileName])
            return false
        }

        let message: [String: Any] = [
            "command": "playSound",
            "fileName": fileName,
            "profile": profileName,
            "volume": Double(volume),
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundWatch",
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                AppDiagnostics.record(
                    "watch.playSound.sendMessage.error",
                    [
                        "file": fileName,
                        "profile": profileName,
                        "error": error.localizedDescription,
                    ]
                )
            }
            AppDiagnostics.record("watch.playSound.sent", ["file": fileName, "profile": profileName])
            return true
        }

        session.transferUserInfo(message)
        AppDiagnostics.record("watch.playSound.queued", ["file": fileName, "profile": profileName])
        return true
    }

    @discardableResult
    func sendRecognitionEvent(_ event: [String: Any]) -> Bool {
        guard let session else {
            AppDiagnostics.record("watch.recognitionEvent.unsupported")
            return false
        }

        var message = event
        message["command"] = "watchRecognitionEvent"
        message["testRunId"] = message["testRunId"] as? String ?? AppDiagnostics.currentRunID()
        message["buildCommit"] = message["buildCommit"] as? String ?? AppDiagnostics.currentBuildCommit()
        message["deviceRole"] = "watchOS"
        message["eventType"] = "watchRecognitionEvent"
        message["sentAt"] = Date().timeIntervalSince1970
        message["source"] = "MotionSoundWatch"

        session.transferUserInfo(message)
        recognitionEventSyncCount += 1
        AppDiagnostics.record(
            "watch.recognitionEvent.queued",
            [
                "count": recognitionEventSyncCount,
                "profile": message["profileName"] as? String ?? "",
                "outcome": message["outcome"] as? String ?? "",
                "triggered": message["triggered"] as? Bool ?? false,
            ]
        )
        return true
    }

    private func receiveAudio(fileURL: URL, preferredFileName: String?, checksum: String?) {
        do {
            let directory = try WatchSoundPlayer.soundsDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let preferredName = preferredFileName?.isEmpty == false
                ? preferredFileName!
                : fileURL.lastPathComponent
            let destination = directory.appendingPathComponent(sanitizeFileName(preferredName))

            if let checksum, let actualChecksum = sha256Hex(fileURL), checksum != actualChecksum {
                lastTransferMessage = "音频校验失败：\(preferredName)"
                AppDiagnostics.record("watch.connectivity.receiveAudio.checksumMismatch", ["file": preferredName])
                return
            }

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: fileURL, to: destination)
            reloadReceivedSoundFiles()
            refreshManifestReadinessIfPossible(reason: "audioReceived")
            lastTransferMessage = "已接收音频：\(destination.lastPathComponent)"
            AppDiagnostics.record("watch.connectivity.receiveAudio", ["file": destination.lastPathComponent])
        } catch {
            lastTransferMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.connectivity.receiveAudio.error", ["file": preferredFileName ?? fileURL.lastPathComponent])
        }
    }

    private func receiveProfile(
        fileURL: URL,
        preferredFileName: String?,
        checksum: String?,
        replaceLibrary: Bool,
        incomingLibraryVersion: String?,
        incomingProfileCount: Int?
    ) {
        do {
            if let checksum, let actualChecksum = sha256Hex(fileURL), checksum != actualChecksum {
                lastTransferMessage = "Profile 校验失败：\(preferredFileName ?? fileURL.lastPathComponent)"
                AppDiagnostics.record("watch.connectivity.receiveProfile.checksumMismatch", ["file": preferredFileName ?? fileURL.lastPathComponent])
                return
            }

            let data = try Data(contentsOf: fileURL)
            let archive = try GestureProfileCodec().decode(data)
            let resolvedLibraryVersion = incomingLibraryVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? incomingLibraryVersion!
                : (pendingProfileManifest?.libraryVersion ?? archive.libraryVersion ?? "single-\(Int(Date().timeIntervalSince1970))")
            let resolvedProfileCount = incomingProfileCount ?? archive.profiles.count

            if replaceLibrary,
               isProfileLibraryReady,
               profileLibraryVersion == resolvedLibraryVersion,
               profileLibraryProfileCount == resolvedProfileCount {
                try? fileManager.removeItem(at: fileURL)
                lastTransferMessage = "Watch 动作库已是最新：\(archive.profiles.count) 个动作"
                AppDiagnostics.record(
                    "watch.profileLibrary.duplicateIgnored",
                    [
                        "profiles": archive.profiles.count,
                        "profileLibraryVersion": resolvedLibraryVersion,
                    ]
                )
                return
            }

            let store = try GestureProfileFileStore.appDocumentsStore()
            try fileManager.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
            if replaceLibrary {
                try deleteAllProfiles(in: store)
            } else {
                try deleteProfiles(matching: archive.profiles, in: store)
            }

            let preferredName = preferredFileName?.isEmpty == false
                ? preferredFileName!
                : fileURL.lastPathComponent
            let destination = availableDestinationURL(
                directory: store.directoryURL,
                fileName: sanitizeProfileFileName(preferredName)
            )
            try fileManager.moveItem(at: fileURL, to: destination)
            lastReceivedProfileURL = destination
            if replaceLibrary {
                profileLibraryVersion = resolvedLibraryVersion
                profileLibraryProfileCount = resolvedProfileCount
                missingProfileAudioFileNames = missingAudioFiles(for: pendingProfileManifest)
                isProfileLibraryReady = missingProfileAudioFileNames.isEmpty
            } else if profileLibraryVersion == nil {
                profileLibraryVersion = resolvedLibraryVersion
                profileLibraryProfileCount = archive.profiles.count
            }
            profileLibraryChangeCount += 1
            lastTransferMessage = replaceLibrary
                ? "已替换 Watch 动作库：\(archive.profiles.count) 个动作"
                : "已接收 Profile：\(destination.lastPathComponent)"
            AppDiagnostics.record(
                "watch.connectivity.receiveProfile",
                [
                    "file": destination.lastPathComponent,
                    "profiles": archive.profiles.count,
                    "replaceLibrary": replaceLibrary,
                    "profileLibraryVersion": resolvedLibraryVersion,
                    "missingAudioCount": missingProfileAudioFileNames.count,
                    "profileLibraryReady": isProfileLibraryReady,
                ]
            )
            if replaceLibrary {
                AppDiagnostics.record(
                    "watch.profileLibrary.ready",
                    [
                        "profileLibraryVersion": resolvedLibraryVersion,
                        "profileCount": archive.profiles.count,
                        "missingAudioCount": missingProfileAudioFileNames.count,
                    ]
                )
                sendProfileSyncAck(
                    applied: isProfileLibraryReady,
                    reason: isProfileLibraryReady ? nil : "missingAudio",
                    profileCount: archive.profiles.count
                )
            } else {
                AppDiagnostics.record(
                    "watch.profileLibrary.notReady",
                    [
                        "reason": "individualProfileTransfer",
                        "profileLibraryVersion": resolvedLibraryVersion,
                    ]
                )
            }
        } catch {
            lastTransferMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.connectivity.receiveProfile.error", ["file": preferredFileName ?? fileURL.lastPathComponent])
        }
    }

    private func receiveProfileLibraryManifest(payload: String?, reason: String?) {
        guard let payload,
              let data = Data(base64Encoded: payload),
              let manifest = try? JSONDecoder().decode(ProfileSyncManifest.self, from: data) else {
            lastTransferMessage = "动作库 Manifest 无法解析"
            AppDiagnostics.record("watch.profileLibrary.manifest.invalid", ["reason": reason ?? ""])
            return
        }
        pendingProfileManifest = manifest
        lastProfileSyncTransactionID = manifest.transactionID
        profileLibraryVersion = manifest.libraryVersion
        profileLibraryProfileCount = manifest.profileCount
        missingProfileAudioFileNames = missingAudioFiles(for: manifest)
        isProfileLibraryReady = false
        profileLibraryStateChangeCount += 1
        lastTransferMessage = "正在同步 Watch 动作库..."
        AppDiagnostics.record(
            "watch.profileLibrary.manifest.received",
            [
                "transactionID": manifest.transactionID.uuidString,
                "profileLibraryVersion": manifest.libraryVersion,
                "profileCount": manifest.profileCount,
                "audioCount": manifest.audioChecksumsByFileName.count,
                "missingAudioCount": missingProfileAudioFileNames.count,
                "reason": reason ?? "",
            ]
        )
    }

    private func refreshManifestReadinessIfPossible(reason: String) {
        guard let manifest = pendingProfileManifest,
              profileLibraryVersion == manifest.libraryVersion,
              profileLibraryProfileCount == manifest.profileCount else {
            return
        }
        missingProfileAudioFileNames = missingAudioFiles(for: manifest)
        guard missingProfileAudioFileNames.isEmpty else {
            isProfileLibraryReady = false
            sendProfileSyncAck(applied: false, reason: "missingAudio", profileCount: profileLibraryProfileCount)
            return
        }
        isProfileLibraryReady = true
        profileLibraryStateChangeCount += 1
        lastTransferMessage = "Watch 动作库已同步：\(profileLibraryProfileCount) 个动作"
        sendProfileSyncAck(applied: true, reason: reason, profileCount: profileLibraryProfileCount)
        AppDiagnostics.record(
            "watch.profileLibrary.ready.afterManifest",
            [
                "transactionID": manifest.transactionID.uuidString,
                "profileLibraryVersion": manifest.libraryVersion,
                "profileCount": manifest.profileCount,
                "reason": reason,
            ]
        )
    }

    private func missingAudioFiles(for manifest: ProfileSyncManifest?) -> [String] {
        guard let manifest else { return [] }
        let directory = try? WatchSoundPlayer.soundsDirectory()
        return manifest.audioChecksumsByFileName.keys.sorted().filter { fileName in
            guard let directory else { return true }
            let url = directory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: url.path) else { return true }
            guard let expected = manifest.audioChecksumsByFileName[fileName],
                  !expected.isEmpty else {
                return false
            }
            return sha256Hex(url) != expected
        }
    }

    private func sendProfileSyncAck(applied: Bool, reason: String?, profileCount: Int) {
        guard let session, let manifest = pendingProfileManifest else { return }
        let ack = ProfileSyncAck(
            transactionID: manifest.transactionID,
            libraryVersion: manifest.libraryVersion,
            applied: applied,
            profileCount: profileCount,
            missingAudioFileNames: missingProfileAudioFileNames,
            reason: reason
        )
        do {
            let payload = try JSONEncoder().encode(ack).base64EncodedString()
            let message: [String: Any] = [
                "command": "profileLibrarySyncAck",
                "payload": payload,
                "transactionID": ack.transactionID.uuidString,
                "profileLibraryVersion": ack.libraryVersion,
                "applied": ack.applied,
                "profileCount": ack.profileCount,
                "missingAudioCount": ack.missingAudioFileNames.count,
                "reason": ack.reason ?? "",
                "sentAt": Date().timeIntervalSince1970,
                "source": "MotionSoundWatch",
            ]
            session.transferUserInfo(message)
            AppDiagnostics.record(
                "watch.profileLibrary.ack.queued",
                [
                    "transactionID": ack.transactionID.uuidString,
                    "profileLibraryVersion": ack.libraryVersion,
                    "applied": ack.applied,
                    "profileCount": ack.profileCount,
                    "missingAudioCount": ack.missingAudioFileNames.count,
                    "reason": ack.reason ?? "",
                ]
            )
        } catch {
            AppDiagnostics.record(error: error, event: "watch.profileLibrary.ack.encode.error")
        }
    }

    private func receiveProfileLibrarySyncBegin(
        version: String?,
        profileCount: Int?,
        reason: String?
    ) {
        let normalizedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedVersion = normalizedVersion?.isEmpty == false ? normalizedVersion : nil
        if isProfileLibraryReady,
           let resolvedVersion,
           profileLibraryVersion == resolvedVersion,
           profileCount.map({ $0 == profileLibraryProfileCount }) ?? true {
            AppDiagnostics.record(
                "watch.profileLibrary.syncBegin.skipped",
                [
                    "reason": reason ?? "",
                    "profileLibraryVersion": resolvedVersion,
                    "profileCount": profileCount ?? profileLibraryProfileCount,
                ]
            )
            return
        }

        profileLibraryVersion = resolvedVersion
        profileLibraryProfileCount = profileCount ?? 0
        isProfileLibraryReady = false
        profileLibraryStateChangeCount += 1
        lastTransferMessage = "正在同步 Watch 动作库..."
        AppDiagnostics.record(
            "watch.profileLibrary.syncBegin",
            [
                "reason": reason ?? "",
                "profileLibraryVersion": resolvedVersion ?? "",
                "profileCount": profileCount ?? -1,
            ]
        )
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

    private func receiveDeleteProfile(profileID: String?, name: String?, kind: String?) {
        do {
            let store = try GestureProfileFileStore.appDocumentsStore()
            let profileUUID = profileID.flatMap(UUID.init(uuidString:))
            let storedArchives = try store.list()
            var deletedCount = 0

            for stored in storedArchives {
                let shouldDelete = stored.archive.profiles.contains { profile in
                    if let profileUUID, profile.id == profileUUID {
                        return true
                    }
                    guard let name,
                          profile.name.caseInsensitiveCompare(name) == .orderedSame else {
                        return false
                    }
                    return true
                }
                guard shouldDelete else { continue }
                try store.delete(fileURL: stored.fileURL)
                deletedCount += 1
            }

            profileLibraryChangeCount += 1
            lastTransferMessage = deletedCount > 0 ? "已删除动作：\(name ?? profileID ?? "")" : "没有找到要删除的动作"
            AppDiagnostics.record(
                "watch.connectivity.deleteProfile",
                [
                    "profileID": profileID ?? "",
                    "name": name ?? "",
                    "kind": kind ?? "",
                    "deleted": deletedCount,
                ]
            )
        } catch {
            lastTransferMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.connectivity.deleteProfile.error", ["name": name ?? ""])
        }
    }

    private func deleteAllProfiles(in store: GestureProfileFileStore) throws {
        let storedArchives = try store.list()
        for stored in storedArchives {
            try store.delete(fileURL: stored.fileURL)
        }
        AppDiagnostics.record("watch.connectivity.profileLibrary.cleared", ["files": storedArchives.count])
    }

    private func deleteProfiles(matching profiles: [GestureProfile], in store: GestureProfileFileStore) throws {
        guard !profiles.isEmpty else { return }
        let storedArchives = try store.list()

        for stored in storedArchives {
            let shouldDelete = stored.archive.profiles.contains { existing in
                profiles.contains { incoming in
                    existing.id == incoming.id
                        || existing.name.caseInsensitiveCompare(incoming.name) == .orderedSame
                }
            }
            if shouldDelete {
                try store.delete(fileURL: stored.fileURL)
            }
        }
    }

    private func receivePrepareRuntime(reason: String?) {
        runtimePrepareRequestCount += 1
        lastTransferMessage = "手机已准备监听"
        AppDiagnostics.record(
            "watch.connectivity.prepareRuntime.received",
            ["reason": reason ?? "", "count": runtimePrepareRequestCount]
        )
    }

    private func receiveConfigureDiagnostics(runID: String?, buildCommit: String?, clearLogs: Bool?, reason: String?) {
        guard let runID, !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppDiagnostics.record("watch.diagnostics.configure.missingRunID", ["reason": reason ?? ""])
            return
        }
        AppDiagnostics.configureRun(
            id: runID,
            buildCommit: buildCommit,
            clearExisting: clearLogs ?? false,
            reason: reason ?? "phoneConfigure"
        )
        lastTransferMessage = "诊断已同步"
        AppDiagnostics.record(
            "watch.diagnostics.configured",
            [
                "runID": AppDiagnostics.currentRunID(),
                "clear": clearLogs ?? false,
                "reason": reason ?? "",
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

private enum WatchRecordingStatusTransport {
    static func send(
        session: WCSession,
        message: [String: Any],
        onError: @MainActor @escaping (String) -> Void
    ) {
        session.sendMessage(message, replyHandler: nil) { error in
            let errorMessage = error.localizedDescription
            Task { @MainActor in
                onError(errorMessage)
            }
        }
    }
}

extension WatchConnectivityFileSender: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            activationStateDescription = description(for: activationState)
            isPhoneReachable = reachable
            if let error {
                lastTransferMessage = error.localizedDescription
                AppDiagnostics.record(error: error, event: "watch.connectivity.activation.error")
            } else {
                AppDiagnostics.record(
                    "watch.connectivity.activation",
                    [
                        "state": activationStateDescription,
                        "reachable": isPhoneReachable,
                    ]
                )
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let kind = file.metadata?["kind"] as? String
        let preferredFileName = file.metadata?["fileName"] as? String
        let checksum = file.metadata?["checksum"] as? String
        let replaceLibrary = file.metadata?["replaceLibrary"] as? Bool ?? false
        let profileLibraryVersion = file.metadata?["profileLibraryVersion"] as? String
        let profileCount = file.metadata?["profileCount"] as? Int
        let fallbackFileName = file.fileURL.lastPathComponent
        let persistedFileURL: URL

        do {
            persistedFileURL = try Self.persistReceivedTransferFile(
                sourceURL: file.fileURL,
                preferredFileName: preferredFileName
            )
        } catch {
            Task { @MainActor in
                lastTransferMessage = error.localizedDescription
                AppDiagnostics.record(
                    error: error,
                    event: "watch.connectivity.receiveFile.persist.error",
                    ["file": preferredFileName ?? fallbackFileName]
                )
            }
            return
        }

        Task { @MainActor in
            switch kind {
            case SyncedFileKind.audioAsset.rawValue:
                receiveAudio(fileURL: persistedFileURL, preferredFileName: preferredFileName, checksum: checksum)
            case SyncedFileKind.gestureProfile.rawValue:
                receiveProfile(
                    fileURL: persistedFileURL,
                    preferredFileName: preferredFileName,
                    checksum: checksum,
                    replaceLibrary: replaceLibrary,
                    incomingLibraryVersion: profileLibraryVersion,
                    incomingProfileCount: profileCount
                )
            default:
                lastTransferMessage = "忽略未知文件：\(preferredFileName ?? persistedFileURL.lastPathComponent)"
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let command = message["command"] as? String
        let reason = message["reason"] as? String
        let action = message["action"] as? String
        let label = message["label"] as? String
        let kind = message["kind"] as? String
        let sampleRole = message["sampleRole"] as? String
        let autoSendCSV = message["autoSendCSV"] as? Bool
        let profileID = message["profileID"] as? String
        let name = message["name"] as? String
        let testRunID = message["testRunId"] as? String
        let buildCommit = message["buildCommit"] as? String
        let clearLogs = message["clearLogs"] as? Bool
        let profileLibraryVersion = message["profileLibraryVersion"] as? String
        let profileCount = message["profileCount"] as? Int
        let payload = message["payload"] as? String
        Task { @MainActor in
            if command == "configureDiagnostics" {
                receiveConfigureDiagnostics(runID: testRunID, buildCommit: buildCommit, clearLogs: clearLogs, reason: reason)
                return
            }
            if command == "profileLibraryManifest" {
                receiveProfileLibraryManifest(payload: payload, reason: reason)
                return
            }
            if command == "profileLibrarySyncBegin" {
                receiveProfileLibrarySyncBegin(version: profileLibraryVersion, profileCount: profileCount, reason: reason)
                return
            }
            if command == "prepareRuntime" {
                receivePrepareRuntime(reason: reason)
                return
            }
            if command == "deleteProfile" {
                receiveDeleteProfile(profileID: profileID, name: name, kind: kind)
                return
            }
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
        let reason = message["reason"] as? String
        let action = message["action"] as? String
        let label = message["label"] as? String
        let kind = message["kind"] as? String
        let sampleRole = message["sampleRole"] as? String
        let autoSendCSV = message["autoSendCSV"] as? Bool
        let profileID = message["profileID"] as? String
        let name = message["name"] as? String
        let testRunID = message["testRunId"] as? String
        let buildCommit = message["buildCommit"] as? String
        let clearLogs = message["clearLogs"] as? Bool
        let profileLibraryVersion = message["profileLibraryVersion"] as? String
        let profileCount = message["profileCount"] as? Int
        let payload = message["payload"] as? String

        if command == "configureDiagnostics" {
            replyHandler([
                "status": "accepted",
                "command": "configureDiagnostics",
                "receivedAt": Date().timeIntervalSince1970,
            ])
            Task { @MainActor in
                receiveConfigureDiagnostics(runID: testRunID, buildCommit: buildCommit, clearLogs: clearLogs, reason: reason)
            }
            return
        }

        if command == "profileLibraryManifest" {
            replyHandler([
                "status": "accepted",
                "command": "profileLibraryManifest",
                "receivedAt": Date().timeIntervalSince1970,
            ])
            Task { @MainActor in
                receiveProfileLibraryManifest(payload: payload, reason: reason)
            }
            return
        }

        if command == "profileLibrarySyncBegin" {
            replyHandler([
                "status": "accepted",
                "command": "profileLibrarySyncBegin",
                "receivedAt": Date().timeIntervalSince1970,
            ])
            Task { @MainActor in
                receiveProfileLibrarySyncBegin(version: profileLibraryVersion, profileCount: profileCount, reason: reason)
            }
            return
        }

        if command == "prepareRuntime" {
            replyHandler([
                "status": "accepted",
                "command": "prepareRuntime",
                "receivedAt": Date().timeIntervalSince1970,
            ])
            Task { @MainActor in
                receivePrepareRuntime(reason: reason)
            }
            return
        }

        if command == "deleteProfile" {
            replyHandler([
                "status": "accepted",
                "command": "deleteProfile",
                "receivedAt": Date().timeIntervalSince1970,
            ])
            Task { @MainActor in
                receiveDeleteProfile(profileID: profileID, name: name, kind: kind)
            }
            return
        }

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
        let reason = userInfo["reason"] as? String
        let action = userInfo["action"] as? String
        let label = userInfo["label"] as? String
        let kind = userInfo["kind"] as? String
        let sampleRole = userInfo["sampleRole"] as? String
        let autoSendCSV = userInfo["autoSendCSV"] as? Bool
        let profileID = userInfo["profileID"] as? String
        let name = userInfo["name"] as? String
        let testRunID = userInfo["testRunId"] as? String
        let buildCommit = userInfo["buildCommit"] as? String
        let clearLogs = userInfo["clearLogs"] as? Bool
        let profileLibraryVersion = userInfo["profileLibraryVersion"] as? String
        let profileCount = userInfo["profileCount"] as? Int
        let payload = userInfo["payload"] as? String
        Task { @MainActor in
            if command == "configureDiagnostics" {
                receiveConfigureDiagnostics(runID: testRunID, buildCommit: buildCommit, clearLogs: clearLogs, reason: reason)
                return
            }
            if command == "profileLibraryManifest" {
                receiveProfileLibraryManifest(payload: payload, reason: reason)
                return
            }
            if command == "profileLibrarySyncBegin" {
                receiveProfileLibrarySyncBegin(version: profileLibraryVersion, profileCount: profileCount, reason: reason)
                return
            }
            if command == "prepareRuntime" {
                receivePrepareRuntime(reason: reason)
                return
            }
            if command == "deleteProfile" {
                receiveDeleteProfile(profileID: profileID, name: name, kind: kind)
                return
            }
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

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let command = applicationContext["command"] as? String
        let reason = applicationContext["reason"] as? String
        let testRunID = applicationContext["testRunId"] as? String
        let buildCommit = applicationContext["buildCommit"] as? String
        let clearLogs = applicationContext["clearLogs"] as? Bool
        let profileLibraryVersion = applicationContext["profileLibraryVersion"] as? String
        let profileCount = applicationContext["profileCount"] as? Int
        let payload = applicationContext["payload"] as? String
        Task { @MainActor in
            if command == "configureDiagnostics" {
                receiveConfigureDiagnostics(runID: testRunID, buildCommit: buildCommit, clearLogs: clearLogs, reason: reason)
                return
            }
            if command == "profileLibraryManifest" {
                receiveProfileLibraryManifest(payload: payload, reason: reason)
                return
            }
            if command == "profileLibrarySyncBegin" {
                receiveProfileLibrarySyncBegin(version: profileLibraryVersion, profileCount: profileCount, reason: reason)
                return
            }
            guard command == "prepareRuntime" else { return }
            receivePrepareRuntime(reason: reason)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let activationState = session.activationState
        Task { @MainActor in
            isPhoneReachable = reachable
            activationStateDescription = description(for: activationState)
            AppDiagnostics.record(
                "watch.connectivity.reachability",
                [
                    "state": activationStateDescription,
                    "reachable": isPhoneReachable,
                ]
            )
        }
    }

    nonisolated private static func persistReceivedTransferFile(
        sourceURL: URL,
        preferredFileName: String?,
        fileManager: FileManager = .default
    ) throws -> URL {
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MotionSoundWatchTransfers", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let rawName = preferredFileName?.isEmpty == false ? preferredFileName! : sourceURL.lastPathComponent
        let destination = baseDirectory.appendingPathComponent("\(UUID().uuidString)-\(nonisolatedSanitizeFileName(rawName))")
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    nonisolated private static func nonisolatedSanitizeFileName(_ value: String) -> String {
        let fallback = "motion-sound-transfer"
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
}
