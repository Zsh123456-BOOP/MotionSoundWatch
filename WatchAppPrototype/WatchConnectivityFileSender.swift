import Foundation
import WatchConnectivity
import CryptoKit

struct ActiveProfileSelectionCommand: Equatable {
    var profileID: UUID?
    var name: String?
    var reason: String?
    /// 来自 ActiveProfileSyncState 的单调版本号；旧版手机不携带时为 nil。
    var revision: Int?
    var updatedAt: Date?
    var origin: String?
}

@MainActor
final class WatchConnectivityFileSender: NSObject, ObservableObject {
    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var activationStateDescription = "not activated"
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var lastTransferMessage: String?
    @Published private(set) var receivedSoundFiles: [URL] = []
    @Published private(set) var lastReceivedProfileURL: URL?
    @Published private(set) var lastRecordingCommand: RecordingControlCommand?
    @Published private(set) var lastActiveProfileCommand: ActiveProfileSelectionCommand?
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
        // 恢复上次同步完成的动作库状态：Watch 重启后即使 iPhone 不在旁边，
        // 本地已存的动作库也应立即可用，而不是等待重新同步。
        if let persisted = WatchProfileLibraryStateStore.load() {
            profileLibraryVersion = persisted.version
            profileLibraryProfileCount = persisted.profileCount
            isProfileLibraryReady = persisted.isReady
        }
        AppDiagnostics.record(
            "watch.connectivity.init",
            [
                "supported": isSupported,
                "restoredLibraryReady": isProfileLibraryReady,
                "restoredLibraryVersion": profileLibraryVersion ?? "",
            ]
        )
        reloadReceivedSoundFiles()
    }

    private func persistLibraryState() {
        WatchProfileLibraryStateStore.save(
            version: profileLibraryVersion,
            profileCount: profileLibraryProfileCount,
            isReady: isProfileLibraryReady
        )
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
                persistLibraryState()
            } else if profileLibraryVersion == nil {
                profileLibraryVersion = resolvedLibraryVersion
                profileLibraryProfileCount = archive.profiles.count
                persistLibraryState()
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
        persistLibraryState()
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
            persistLibraryState()
            sendProfileSyncAck(applied: false, reason: "missingAudio", profileCount: profileLibraryProfileCount)
            return
        }
        isProfileLibraryReady = true
        persistLibraryState()
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

    private func receiveActiveProfileCommand(
        profileID: String?,
        name: String?,
        reason: String?,
        payload: String? = nil
    ) {
        let command: ActiveProfileSelectionCommand
        if let payload {
            guard let data = Data(base64Encoded: payload),
                  let state = try? MotionSoundSyncCodec.decode(ActiveProfileSyncState.self, from: data) else {
                // payload 损坏时直接忽略，绝不能退化成"清空当前动作"。
                AppDiagnostics.record("watch.connectivity.activeProfile.invalidPayload", ["reason": reason ?? ""])
                return
            }
            command = ActiveProfileSelectionCommand(
                profileID: state.profileID,
                name: state.profileName?.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: reason,
                revision: state.revision,
                updatedAt: state.updatedAt,
                origin: state.origin
            )
        } else {
            // 兼容不带 payload 的旧格式命令。
            command = ActiveProfileSelectionCommand(
                profileID: profileID.flatMap(UUID.init(uuidString:)),
                name: name?.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: reason
            )
        }
        lastActiveProfileCommand = command
        lastTransferMessage = command.profileID == nil && (command.name ?? "").isEmpty
            ? "已清空当前识别动作"
            : "已切换当前识别动作：\(command.name ?? command.profileID?.uuidString ?? "")"
        AppDiagnostics.record(
            "watch.connectivity.activeProfile.received",
            [
                "profileID": command.profileID?.uuidString ?? "",
                "name": command.name ?? "",
                "revision": command.revision ?? -1,
                "reason": reason ?? "",
            ]
        )
    }

    /// 把激活命令的执行结果回报给 iPhone（applied / pending / 失败原因）。
    @discardableResult
    func sendActiveProfileAck(_ ack: ActiveProfileSyncAck) -> Bool {
        guard let session else {
            AppDiagnostics.record("watch.activeProfile.ack.unsupported")
            return false
        }
        do {
            let payload = try MotionSoundSyncCodec.encode(ack).base64EncodedString()
            let message: [String: Any] = [
                "command": "activeProfileAck",
                "payload": payload,
                "revision": ack.revision,
                "profileID": ack.profileID?.uuidString ?? "",
                "applied": ack.applied,
                "pending": ack.pending,
                "reason": ack.reason ?? "",
                "sentAt": Date().timeIntervalSince1970,
                "source": "MotionSoundWatch",
            ]
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { _ in
                    session.transferUserInfo(message)
                }
            } else {
                session.transferUserInfo(message)
            }
            AppDiagnostics.record(
                "watch.activeProfile.ack.sent",
                [
                    "revision": ack.revision,
                    "applied": ack.applied,
                    "pending": ack.pending,
                    "reason": ack.reason ?? "",
                ]
            )
            return true
        } catch {
            AppDiagnostics.record(error: error, event: "watch.activeProfile.ack.encode.error")
            return false
        }
    }

    /// 上报误触反馈到 iPhone：携带动作标识与触发片段样本（CSV）。
    /// iPhone 负责把该片段作为负样本并入权威库并重新下发。
    @discardableResult
    func sendFalseTrigger(profileID: UUID?, profileName: String?, samples: [MotionSample]) -> Bool {
        guard let session else {
            AppDiagnostics.record("watch.falseTrigger.unsupported")
            return false
        }
        guard !samples.isEmpty else { return false }
        let csv = MotionSampleCSVCodec().encode(samples)
        let payload = Data(csv.utf8).base64EncodedString()
        let message: [String: Any] = [
            "command": "gestureFalseTrigger",
            "profileID": profileID?.uuidString ?? "",
            "profileName": profileName ?? "",
            "samplesCSV": payload,
            "sampleCount": samples.count,
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundWatch",
        ]
        // 用 transferUserInfo 保证离线可达时排队送达。
        session.transferUserInfo(message)
        AppDiagnostics.record(
            "watch.falseTrigger.queued",
            ["profile": profileName ?? "", "samples": samples.count]
        )
        return true
    }

    /// Watch 端本地切换当前动作后，把最新状态推给 iPhone。
    @discardableResult
    func sendActiveProfileState(_ state: ActiveProfileSyncState) -> Bool {
        guard let session else {
            AppDiagnostics.record("watch.activeProfile.state.unsupported")
            return false
        }
        do {
            let payload = try MotionSoundSyncCodec.encode(state).base64EncodedString()
            let message: [String: Any] = [
                "command": "activeProfileState",
                "payload": payload,
                "revision": state.revision,
                "profileID": state.profileID?.uuidString ?? "",
                "name": state.profileName ?? "",
                "sentAt": Date().timeIntervalSince1970,
                "source": "MotionSoundWatch",
            ]
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { _ in
                    session.transferUserInfo(message)
                }
            } else {
                session.transferUserInfo(message)
            }
            AppDiagnostics.record(
                "watch.activeProfile.state.sent",
                [
                    "revision": state.revision,
                    "profileID": state.profileID?.uuidString ?? "",
                ]
            )
            return true
        } catch {
            AppDiagnostics.record(error: error, event: "watch.activeProfile.state.encode.error")
            return false
        }
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

/// WCSession 命令的 Sendable 快照：在 nonisolated 代理里从 [String: Any] 提取，
/// 再安全地跨越 actor 边界传给 @MainActor 分发器（满足 Swift 6 严格并发）。
private struct IncomingCommand: Sendable {
    var command: String?
    var reason: String?
    var action: String?
    var label: String?
    var kind: String?
    var sampleRole: String?
    var autoSendCSV: Bool?
    var profileID: String?
    var name: String?
    var testRunID: String?
    var buildCommit: String?
    var clearLogs: Bool?
    var profileLibraryVersion: String?
    var profileCount: Int?
    var payload: String?
    var activeProfileState: String?

    init(_ dict: [String: Any]) {
        command = dict["command"] as? String
        reason = dict["reason"] as? String
        action = dict["action"] as? String
        label = dict["label"] as? String
        kind = dict["kind"] as? String
        sampleRole = dict["sampleRole"] as? String
        autoSendCSV = dict["autoSendCSV"] as? Bool
        profileID = dict["profileID"] as? String
        name = dict["name"] as? String
        testRunID = dict["testRunId"] as? String
        buildCommit = dict["buildCommit"] as? String
        clearLogs = dict["clearLogs"] as? Bool
        profileLibraryVersion = dict["profileLibraryVersion"] as? String
        profileCount = dict["profileCount"] as? Int
        payload = dict["payload"] as? String
        activeProfileState = dict["activeProfileState"] as? String
    }
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
        let incoming = IncomingCommand(message)
        Task { @MainActor in dispatchIncoming(incoming) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let incoming = IncomingCommand(message)
        // sendMessage 需要同步回执；不识别的录制命令仍返回 rejected 以兼容旧逻辑。
        if incoming.command == "recordingControl",
           RecordingControlAction(rawValue: incoming.action ?? "") == nil {
            replyHandler([
                "status": "rejected",
                "reason": "unknownRecordingCommand",
                "receivedAt": Date().timeIntervalSince1970,
            ])
            return
        }
        replyHandler([
            "status": "accepted",
            "command": incoming.command ?? "",
            "receivedAt": Date().timeIntervalSince1970,
        ])
        Task { @MainActor in dispatchIncoming(incoming) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let incoming = IncomingCommand(userInfo)
        Task { @MainActor in dispatchIncoming(incoming) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let incoming = IncomingCommand(applicationContext)
        Task { @MainActor in dispatchIncoming(incoming) }
    }

    /// 单一入口：解析并分发来自 message / userInfo / applicationContext 的命令。
    /// 四条 WCSession 通道此前各有一份重复解析（A7）；现在收敛到这里。
    @MainActor
    private func dispatchIncoming(_ incoming: IncomingCommand) {
        // 常驻 applicationContext 的"当前启用动作"侧信道：与 command 互不排斥，
        // 即使 Watch 离线，重连后也能收敛到最新选择。
        if let activeProfilePayload = incoming.activeProfileState {
            receiveActiveProfileCommand(
                profileID: nil,
                name: nil,
                reason: "applicationContext",
                payload: activeProfilePayload
            )
        }

        switch incoming.command {
        case "configureDiagnostics":
            receiveConfigureDiagnostics(
                runID: incoming.testRunID,
                buildCommit: incoming.buildCommit,
                clearLogs: incoming.clearLogs,
                reason: incoming.reason
            )
        case "profileLibraryManifest":
            receiveProfileLibraryManifest(payload: incoming.payload, reason: incoming.reason)
        case "profileLibrarySyncBegin":
            receiveProfileLibrarySyncBegin(
                version: incoming.profileLibraryVersion,
                profileCount: incoming.profileCount,
                reason: incoming.reason
            )
        case "prepareRuntime":
            receivePrepareRuntime(reason: incoming.reason)
        case "deleteProfile":
            receiveDeleteProfile(profileID: incoming.profileID, name: incoming.name, kind: incoming.kind)
        case "setActiveProfile":
            receiveActiveProfileCommand(
                profileID: incoming.profileID,
                name: incoming.name,
                reason: incoming.reason,
                payload: incoming.payload
            )
        case "recordingControl":
            receiveRecordingCommand(
                action: incoming.action,
                label: incoming.label,
                kind: incoming.kind,
                sampleRole: incoming.sampleRole,
                autoSendCSV: incoming.autoSendCSV
            )
        default:
            break
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

/// 动作库就绪状态的本地持久化：Watch 重启后本地库立即可用，无需等待 iPhone 重新同步。
enum WatchProfileLibraryStateStore {
    private static let versionKey = "MotionSound.profileLibrary.version.v1"
    private static let countKey = "MotionSound.profileLibrary.count.v1"
    private static let readyKey = "MotionSound.profileLibrary.ready.v1"

    struct PersistedState {
        var version: String?
        var profileCount: Int
        var isReady: Bool
    }

    static func load(defaults: UserDefaults = .standard) -> PersistedState? {
        guard defaults.object(forKey: readyKey) != nil else { return nil }
        return PersistedState(
            version: defaults.string(forKey: versionKey),
            profileCount: defaults.integer(forKey: countKey),
            isReady: defaults.bool(forKey: readyKey)
        )
    }

    static func save(version: String?, profileCount: Int, isReady: Bool, defaults: UserDefaults = .standard) {
        if let version {
            defaults.set(version, forKey: versionKey)
        } else {
            defaults.removeObject(forKey: versionKey)
        }
        defaults.set(profileCount, forKey: countKey)
        defaults.set(isReady, forKey: readyKey)
    }
}
