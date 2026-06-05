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

struct WatchRecognitionEventSummary: Identifiable, Equatable {
    var id: URL { fileURL }
    var fileURL: URL
    var fileName: String
    var profileID: UUID?
    var profileName: String
    var variantLabel: String?
    var outcome: String
    var triggered: Bool
    var audioPlayed: Bool
    var recognizerKind: String
    var rejectReason: String?
    var createdAt: Date
    var receivedAt: Date
}

struct ProfileSyncResult: Equatable {
    var fileURL: URL
    var archive: GestureProfileArchive
    var didQueueTransfer: Bool
}

private struct RecordingCommandReply {
    var status: String?
    var action: String?
    var samples: Int?
}

private enum PhoneConnectivityReceiverError: LocalizedError {
    case invalidWatchEvent

    var errorDescription: String? {
        switch self {
        case .invalidWatchEvent:
            return "Watch 事件不是有效 JSON。"
        }
    }
}

private enum PhoneRecordingCommandTransport {
    static func send(
        session: WCSession,
        message: [String: Any],
        onReply: @MainActor @escaping (RecordingCommandReply) -> Void,
        onError: @MainActor @escaping (String) -> Void
    ) {
        session.sendMessage(message) { reply in
            let commandReply = RecordingCommandReply(
                status: reply["status"] as? String,
                action: reply["action"] as? String,
                samples: reply["samples"] as? Int
            )
            Task { @MainActor in
                onReply(commandReply)
            }
        } errorHandler: { error in
            let errorMessage = error.localizedDescription
            Task { @MainActor in
                onError(errorMessage)
            }
        }
    }
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
    @Published private(set) var receivedWatchEventCount = 0
    @Published private(set) var lastWatchEventFileName: String?
    @Published private(set) var recentWatchEvents: [WatchRecognitionEventSummary] = []

    private let fileManager: FileManager
    private let soundPlayer: PhoneSoundPlayer

    init(fileManager: FileManager = .default, soundPlayer: PhoneSoundPlayer = PhoneSoundPlayer()) {
        self.fileManager = fileManager
        self.soundPlayer = soundPlayer
        super.init()
        AppDiagnostics.record("phone.connectivity.init", ["supported": isSupported])
        reloadReceivedFiles()
        reloadWatchEventCount()
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
        _ = sendDiagnosticsConfiguration(reason: "activate")
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
    func sendDiagnosticsConfiguration(reason: String, clearWatchLogs: Bool = false) -> Bool {
        guard let session else {
            AppDiagnostics.record("phone.diagnostics.configureWatch.unsupported", ["reason": reason])
            return false
        }
        guard session.activationState == .activated else {
            AppDiagnostics.record(
                "phone.diagnostics.configureWatch.deferred",
                ["reason": reason, "state": Self.description(for: session.activationState)]
            )
            return false
        }

        let message: [String: Any] = [
            "command": "configureDiagnostics",
            "testRunId": AppDiagnostics.currentRunID(),
            "buildCommit": AppDiagnostics.currentBuildCommit(),
            "clearLogs": clearWatchLogs,
            "reason": reason,
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundPhone",
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                AppDiagnostics.record(
                    "phone.diagnostics.configureWatch.sendMessage.error",
                    ["reason": reason, "error": error.localizedDescription]
                )
            }
            AppDiagnostics.record("phone.diagnostics.configureWatch.sent", ["reason": reason, "clear": clearWatchLogs])
            return true
        }

        do {
            try session.updateApplicationContext(message)
            AppDiagnostics.record("phone.diagnostics.configureWatch.contextUpdated", ["reason": reason, "clear": clearWatchLogs])
            return true
        } catch {
            session.transferUserInfo(message)
            AppDiagnostics.record(error: error, event: "phone.diagnostics.configureWatch.context.error", ["reason": reason])
            return true
        }
    }

    @discardableResult
    func requestWatchRuntime(reason: String) -> Bool {
        guard let session else {
            AppDiagnostics.record("phone.prepareRuntime.unsupported", ["reason": reason])
            return false
        }
        guard session.activationState == .activated else {
            AppDiagnostics.record(
                "phone.prepareRuntime.deferred",
                ["reason": reason, "state": Self.description(for: session.activationState)]
            )
            return false
        }

        let message: [String: Any] = [
            "command": "prepareRuntime",
            "reason": reason,
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundPhone",
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                AppDiagnostics.record(
                    "phone.prepareRuntime.sendMessage.error",
                    ["reason": reason, "error": error.localizedDescription]
                )
            }
            AppDiagnostics.record("phone.prepareRuntime.sent", ["reason": reason, "reachable": true])
            return true
        }

        do {
            try session.updateApplicationContext(message)
            AppDiagnostics.record("phone.prepareRuntime.contextUpdated", ["reason": reason, "reachable": false])
            return true
        } catch {
            AppDiagnostics.record(error: error, event: "phone.prepareRuntime.context.error", ["reason": reason])
            return false
        }
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
            PhoneRecordingCommandTransport.send(
                session: session,
                message: message
            ) { [weak self] reply in
                AppDiagnostics.record(
                    "phone.recordingCommand.reply",
                    [
                        "status": reply.status ?? "",
                        "action": reply.action ?? "",
                        "samples": reply.samples ?? -1,
                    ]
                )
                if reply.status == "accepted" {
                    if reply.action == RecordingControlAction.startRecording.rawValue {
                        self?.lastMessage = "Watch 已确认开始录制"
                    } else if let samples = reply.samples {
                        self?.lastMessage = "Watch 已确认停止录制，样本 \(samples)"
                    } else {
                        self?.lastMessage = "Watch 已确认停止录制"
                    }
                } else {
                    self?.lastMessage = "Watch 回执异常"
                }
            } onError: { [weak self] errorMessage in
                self?.queueRecordingCommand(
                    session: session,
                    message: message,
                    action: action,
                    label: label,
                    kind: kind,
                    sampleRole: sampleRole,
                    autoSendCSV: autoSendCSV,
                    errorMessage: errorMessage
                )
                AppDiagnostics.record(
                    "phone.recordingCommand.sendMessage.error",
                    [
                        "action": action.rawValue,
                        "error": errorMessage,
                    ]
                )
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

        queueRecordingCommand(
            session: session,
            message: message,
            action: action,
            label: label,
            kind: kind,
            sampleRole: sampleRole,
            autoSendCSV: autoSendCSV
        )
        return true
    }

    private func queueRecordingCommand(
        session: WCSession,
        message: [String: Any],
        action: RecordingControlAction,
        label: String,
        kind: String,
        sampleRole: String,
        autoSendCSV: Bool,
        errorMessage: String? = nil
    ) {
        session.transferUserInfo(message)
        lastMessage = action == .startRecording
            ? "Watch 即时不可达，已排队开始录制；打开 Watch App 后会执行。"
            : "Watch 即时不可达，已排队结束录制；等待 Watch 保存并同步样本。"
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
                "error": errorMessage ?? "",
            ]
        )
    }

    @discardableResult
    func sendAudioFile(_ sourceURL: URL) -> Bool {
        sendFile(sourceURL, kind: .audioAsset, queuedMessagePrefix: "已加入音频发送队列")
    }

    @discardableResult
    func previewAudioFile(_ sourceURL: URL, volume: Float = 1) -> Bool {
        let played = soundPlayer.play(fileName: sourceURL.lastPathComponent, volume: volume)
        lastMessage = played ? "正在试听：\(sourceURL.lastPathComponent)" : "试听失败：\(sourceURL.lastPathComponent)"
        AppDiagnostics.record(
            "phone.audio.preview",
            [
                "file": sourceURL.lastPathComponent,
                "played": played,
            ]
        )
        return played
    }

    @discardableResult
    func sendProfileFile(_ sourceURL: URL) -> Bool {
        sendFile(sourceURL, kind: .gestureProfile, queuedMessagePrefix: "已加入 Profile 发送队列")
    }

    @discardableResult
    func sendProfileLibrarySnapshot() -> Bool {
        do {
            let store = try GestureProfileFileStore.appDocumentsStore(fileManager: fileManager)
            let profiles = try store.list()
                .flatMap(\.archive.profiles)
                .filter { !Self.isLegacyUntitledProfile($0) }
            let archive = GestureProfileArchive(profiles: profiles)
            let data = try GestureProfileCodec().encode(archive)
            let snapshotURL = fileManager.temporaryDirectory
                .appendingPathComponent("MotionSoundProfileLibrary-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: snapshotURL, options: [.atomic])
            return sendFile(
                snapshotURL,
                kind: .gestureProfile,
                queuedMessagePrefix: "已加入 Watch 动作库替换队列",
                extraMetadata: ["replaceLibrary": true]
            )
        } catch {
            lastMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.profile.librarySnapshot.error")
            return false
        }
    }

    func generateAndSendProfile(
        gesture: String,
        kind kindRawValue: String,
        soundFileName: String? = nil,
        soundSequenceFileNames: [String] = [],
        primarySamplesOverride: [MotionSample]? = nil,
        baseTemplates: [MotionTemplate] = [],
        cooldownSeconds: Double = 0.8,
        triggerTimingRawValue: String = TriggerTiming.atEnd.rawValue,
        volume: Double = 1,
        replacingProfileID: UUID? = nil,
        replacingName: String? = nil
    ) -> ProfileSyncResult? {
        let trimmedGesture = gesture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGesture.isEmpty else {
            lastMessage = "动作名称为空"
            return nil
        }
        guard let requestedKind = GestureKind(rawValue: kindRawValue) else {
            lastMessage = "动作配置无效：\(kindRawValue)"
            return nil
        }

        do {
            let csvFiles = receivedFiles
                .filter { $0.fileURL.pathExtension.lowercased() == "csv" }
                .filter { Self.parseCaptureFileName($0.fileURL.deletingPathExtension().lastPathComponent).gesture == trimmedGesture }

            var primaryTemplates: [MotionTemplate] = []
            let csvCodec = MotionSampleCSVCodec()
            let templateBuilder = MotionTemplateBuilder()
            let csvPrimarySampleSets = try csvFiles.compactMap { file -> [MotionSample]? in
                let parsed = Self.parseCaptureFileName(file.fileURL.deletingPathExtension().lastPathComponent)
                guard ["sample", "positive", "watch", "unknown"].contains(parsed.role) else {
                    return nil
                }
                let samples = try csvCodec.decodeData(Data(contentsOf: file.fileURL))
                return samples.isEmpty ? nil : samples
            }
            let classificationSampleSets = Self.classificationSampleSets(
                primarySamplesOverride: primarySamplesOverride,
                baseTemplates: baseTemplates,
                csvPrimarySampleSets: csvPrimarySampleSets
            )
            let effectiveKind = Self.effectiveKind(
                requestedKind: requestedKind,
                sampleSets: classificationSampleSets
            )
            let preparedPrimarySamples = primarySamplesOverride.map {
                Self.preparedTemplateSamples($0, requestedKind: effectiveKind)
            }
            let preparedBaseTemplates = baseTemplates.map {
                Self.preparedTemplate(from: $0, kind: effectiveKind, builder: templateBuilder)
            }
            primaryTemplates.append(contentsOf: preparedBaseTemplates)

            if let preparedPrimarySamples, !preparedPrimarySamples.isEmpty {
                primaryTemplates.append(templateBuilder.makeTemplate(
                    label: trimmedGesture,
                    kind: effectiveKind,
                    samples: preparedPrimarySamples
                ))
                AppDiagnostics.record(
                    "phone.profile.primarySamplesOverride",
                    [
                        "gesture": trimmedGesture,
                        "samples": preparedPrimarySamples.count,
                        "rawSamples": primarySamplesOverride?.count ?? 0,
                        "requestedKind": requestedKind.rawValue,
                        "effectiveKind": effectiveKind.rawValue,
                    ]
                )
            }

            if primarySamplesOverride == nil, baseTemplates.isEmpty {
                for samples in csvPrimarySampleSets {
                    let preparedSamples = Self.preparedTemplateSamples(samples, requestedKind: effectiveKind)
                    primaryTemplates.append(templateBuilder.makeTemplate(
                        label: trimmedGesture,
                        kind: effectiveKind,
                        samples: preparedSamples
                    ))
                }
            }

            guard !primaryTemplates.isEmpty else {
                lastMessage = "没有可生成 Profile 的录制片段：\(trimmedGesture)"
                return nil
            }

            let localStore = try GestureProfileFileStore.appDocumentsStore()
            let existingArchives = try localStore.list()
            let existingProfiles = existingArchives.flatMap(\.archive.profiles)
            let comparableExistingProfiles = existingProfiles.filter { existing in
                if let replacingProfileID, existing.id == replacingProfileID {
                    return false
                }
                if let replacingName, existing.name.caseInsensitiveCompare(replacingName) == .orderedSame {
                    return false
                }
                return true
            }
            let sounds = normalizedSoundAssets(fileNames: soundSequenceFileNames, volume: volume)
            let sound = sounds.first ?? normalizedSoundAsset(fileName: soundFileName, volume: volume)
            var profile = GestureProfileBuilder().makeProfile(
                name: trimmedGesture,
                kind: effectiveKind,
                templates: primaryTemplates,
                negativeTemplates: [],
                sound: sound,
                existingProfiles: comparableExistingProfiles,
                cooldownSeconds: cooldownSeconds
            )
            profile.soundSequence = sounds.count > 1 ? sounds : nil
            if let triggerTiming = TriggerTiming(rawValue: triggerTimingRawValue) {
                profile.triggerTiming = triggerTiming
            }
            if let conflict = existingProfiles.first(where: { existing in
                guard existing.name.caseInsensitiveCompare(profile.name) == .orderedSame else {
                    return false
                }
                if let replacingProfileID, existing.id == replacingProfileID {
                    return false
                }
                if let replacingName, existing.name.caseInsensitiveCompare(replacingName) == .orderedSame {
                    return false
                }
                return true
            }) {
                lastMessage = "动作名已存在：\(conflict.name)，请重新命名。"
                AppDiagnostics.record(
                    "phone.profile.nameConflict",
                    [
                        "gesture": trimmedGesture,
                        "conflictID": conflict.id.uuidString,
                    ]
                )
                return nil
            }
            let matchingArchives = existingArchives.filter { stored in
                stored.archive.profiles.contains {
                    if let replacingProfileID, $0.id == replacingProfileID {
                        return true
                    }
                    if let replacingName, $0.name.caseInsensitiveCompare(replacingName) == .orderedSame {
                        return true
                    }
                    return false
                }
            }
            if let existingProfile = matchingArchives
                .flatMap(\.archive.profiles)
                .first(where: {
                    if let replacingProfileID, $0.id == replacingProfileID {
                        return true
                    }
                    if let replacingName, $0.name.caseInsensitiveCompare(replacingName) == .orderedSame {
                        return true
                    }
                    return false
                }) {
                profile.id = existingProfile.id
                profile.createdAt = existingProfile.createdAt
            }
            if let replacingProfileID {
                profile.id = replacingProfileID
            }
            for stored in matchingArchives {
                try? localStore.delete(fileURL: stored.fileURL)
            }

            let archive = GestureProfileArchive(profiles: [profile])
            let localURL = try localStore.save(archive, preferredName: trimmedGesture)
            let didQueueTransfer = sendProfileFile(localURL)
            lastMessage = "已保存动作：\(profile.name)"
            AppDiagnostics.record(
                "phone.profile.saved",
                [
                    "file": localURL.lastPathComponent,
                    "gesture": trimmedGesture,
                    "requestedKind": requestedKind.rawValue,
                    "effectiveKind": effectiveKind.rawValue,
                    "templates": primaryTemplates.count,
                    "baseTemplates": baseTemplates.count,
                    "classificationSamples": classificationSampleSets.count,
                    "preparedBaseTemplates": preparedBaseTemplates.count,
                    "negativeTemplates": 0,
                    "soundSequenceCount": profile.soundSequence?.count ?? 0,
                    "queued": didQueueTransfer,
                ]
            )
            return ProfileSyncResult(fileURL: localURL, archive: archive, didQueueTransfer: didQueueTransfer)
        } catch {
            lastMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.profile.generate.error", ["gesture": trimmedGesture])
            return nil
        }
    }

    @discardableResult
    func sendDeleteProfileCommand(profileID: UUID, name: String, kind: GestureKind) -> Bool {
        guard let session else {
            lastMessage = "当前设备不支持 WatchConnectivity"
            AppDiagnostics.record("phone.profile.deleteCommand.unsupported", ["profile": name])
            return false
        }

        let message: [String: Any] = [
            "command": "deleteProfile",
            "profileID": profileID.uuidString,
            "name": name,
            "kind": kind.rawValue,
            "sentAt": Date().timeIntervalSince1970,
            "source": "MotionSoundPhone",
        ]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                AppDiagnostics.record(
                    "phone.profile.deleteCommand.sendMessage.error",
                    ["profile": name, "error": error.localizedDescription]
                )
            }
            lastMessage = "已发送删除到 Watch：\(name)"
            AppDiagnostics.record("phone.profile.deleteCommand.sent", ["profile": name, "reachable": true])
            return true
        }

        session.transferUserInfo(message)
        lastMessage = "Watch 当前不可达，已排队删除：\(name)"
        AppDiagnostics.record("phone.profile.deleteCommand.queued", ["profile": name, "reachable": false])
        return true
    }

    @discardableResult
    private func sendFile(
        _ sourceURL: URL,
        kind: SyncedFileKind,
        queuedMessagePrefix: String,
        extraMetadata: [String: Any] = [:]
    ) -> Bool {
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
            let preferredFileName = sanitizeFileName(sourceURL.lastPathComponent)
            var metadata: [String: Any] = [
                "kind": kind.rawValue,
                "fileName": preferredFileName,
                "transferFileName": fileURL.lastPathComponent,
                "sentAt": Date().timeIntervalSince1970,
                "source": "MotionSoundPhone",
                "checksum": try sha256Hex(fileURL),
            ]
            for (key, value) in extraMetadata {
                metadata[key] = value
            }
            session.transferFile(fileURL, metadata: metadata)
            lastMessage = "\(queuedMessagePrefix)：\(fileURL.lastPathComponent)"
            AppDiagnostics.record(
                "phone.connectivity.transfer.queued",
                [
                    "file": fileURL.lastPathComponent,
                    "preferredFileName": preferredFileName,
                    "kind": kind.rawValue,
                ]
            )
            return true
        } catch {
            lastMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.connectivity.transfer.error", ["file": sourceURL.lastPathComponent, "kind": kind.rawValue])
            return false
        }
    }

    private func finishReceivedFile(_ destination: URL) {
        lastMessage = "已接收：\(destination.lastPathComponent)"
        AppDiagnostics.record("phone.connectivity.receiveFile", ["file": destination.lastPathComponent])
        reloadReceivedFiles()
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

    private func receivePlaySound(
        command: String?,
        fileName: String?,
        profile: String?,
        volume: Double?
    ) {
        guard command == "playSound" else { return }
        let trimmedFileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedFileName.isEmpty else {
            lastMessage = "Watch 触发了动作，但没有音频文件名。"
            AppDiagnostics.record("phone.playSound.emptyFileName", ["profile": profile ?? ""])
            return
        }

        lastMessage = "Watch 触发：\(profile ?? "")，手机不代播；请以 Watch 声音为准。"
        AppDiagnostics.record(
            "phone.playSound.ignored",
            [
                "file": trimmedFileName,
                "profile": profile ?? "",
                "volume": volume ?? 1,
            ]
        )
    }

    private func receiveWatchRecognitionEvent(_ message: [String: Any]) {
        do {
            let fileName = try Self.persistWatchRecognitionEvent(message)
            noteWatchEventSaved(fileName: fileName)
            reloadWatchEventCount()
        } catch {
            AppDiagnostics.record(error: error, event: "phone.watchEvent.receive.error")
        }
    }

    private func noteWatchEventSaved(fileName: String) {
        lastWatchEventFileName = fileName
        AppDiagnostics.record("phone.watchEvent.received", ["file": fileName])
    }

    private func reloadWatchEventCount() {
        do {
            let directory = try AppDiagnostics.watchEventsDirectory(fileManager: fileManager)
            guard fileManager.fileExists(atPath: directory.path) else {
                receivedWatchEventCount = 0
                lastWatchEventFileName = nil
                return
            }
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate($0) > modificationDate($1) }
            receivedWatchEventCount = files.count
            lastWatchEventFileName = files.first?.lastPathComponent
            recentWatchEvents = files.prefix(80).compactMap(Self.watchRecognitionEventSummary)
        } catch {
            receivedWatchEventCount = 0
            recentWatchEvents = []
            AppDiagnostics.record(error: error, event: "phone.watchEvent.reload.error")
        }
    }

    private static func watchRecognitionEventSummary(fileURL: URL) -> WatchRecognitionEventSummary? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let timestampFormatter = ISO8601DateFormatter()
        let createdAt = (json["createdAt"] as? String).flatMap(timestampFormatter.date(from:))
            ?? ((try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            ?? .distantPast
        let receivedAt = (json["receivedAt"] as? String).flatMap(timestampFormatter.date(from:))
            ?? ((try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            ?? createdAt
        let profileID = (json["profileID"] as? String).flatMap(UUID.init(uuidString:))
        let profileName = (json["profileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rejectReason = (json["rejectReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let variantLabel = (json["variantLabel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return WatchRecognitionEventSummary(
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            profileID: profileID,
            profileName: profileName?.isEmpty == false ? profileName! : "未命中",
            variantLabel: variantLabel?.isEmpty == false ? variantLabel : nil,
            outcome: (json["outcome"] as? String) ?? "event",
            triggered: (json["triggered"] as? Bool) ?? false,
            audioPlayed: (json["audioPlayed"] as? Bool) ?? false,
            recognizerKind: (json["recognizerKind"] as? String) ?? "",
            rejectReason: rejectReason?.isEmpty == false ? rejectReason : nil,
            createdAt: createdAt,
            receivedAt: receivedAt
        )
    }

    nonisolated private static func persistWatchRecognitionEvent(
        _ message: [String: Any],
        fileManager: FileManager = .default
    ) throws -> String {
        let directory = try AppDiagnostics.watchEventsDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var event = message
        event["receivedAt"] = ISO8601DateFormatter().string(from: Date())
        event["receivedBy"] = "MotionSoundPhone"
        event["testRunId"] = event["testRunId"] as? String ?? AppDiagnostics.currentRunID()
        event["buildCommit"] = event["buildCommit"] as? String ?? AppDiagnostics.currentBuildCommit()
        event["eventType"] = event["eventType"] as? String ?? "watchRecognitionEvent"

        guard JSONSerialization.isValidJSONObject(event) else {
            throw PhoneConnectivityReceiverError.invalidWatchEvent
        }

        let data = try JSONSerialization.data(withJSONObject: event, options: [.prettyPrinted, .sortedKeys])
        let fileName = watchEventFileName(event)
        try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
        return fileName
    }

    nonisolated private static func watchEventFileName(_ event: [String: Any]) -> String {
        let timestamp = (event["createdAt"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        let outcome = nonisolatedSanitizeFileName((event["outcome"] as? String) ?? "event")
        let profile = nonisolatedSanitizeFileName((event["profileName"] as? String) ?? "no-profile")
        let compactTimestamp = timestamp
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "T", with: "-")
            .replacingOccurrences(of: "Z", with: "")
        return "\(compactTimestamp)-\(outcome)-\(profile).json"
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

    private func normalizedSoundAsset(fileName: String?, volume: Double = 1) -> SoundAsset? {
        guard let fileName else { return nil }
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SoundAsset(fileName: trimmed, duration: 0, volume: Float(max(0, min(1, volume))))
    }

    private func normalizedSoundAssets(fileNames: [String], volume: Double = 1) -> [SoundAsset] {
        var seen: Set<String> = []
        return fileNames.compactMap { fileName in
            let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return SoundAsset(fileName: trimmed, duration: 0, volume: Float(max(0, min(1, volume))))
        }
    }

    nonisolated private static func classificationSampleSets(
        primarySamplesOverride: [MotionSample]?,
        baseTemplates: [MotionTemplate],
        csvPrimarySampleSets: [[MotionSample]]
    ) -> [[MotionSample]] {
        var sampleSets: [[MotionSample]] = []
        if let primarySamplesOverride, !primarySamplesOverride.isEmpty {
            sampleSets.append(primarySamplesOverride)
        }
        sampleSets.append(contentsOf: baseTemplates.map(\.samples).filter { !$0.isEmpty })
        if sampleSets.isEmpty {
            sampleSets.append(contentsOf: csvPrimarySampleSets)
        }
        return sampleSets
    }

    nonisolated private static func effectiveKind(
        requestedKind: GestureKind,
        sampleSets: [[MotionSample]]
    ) -> GestureKind {
        guard requestedKind != .posture, requestedKind != .combo else { return requestedKind }
        let sampleSets = sampleSets.filter { !$0.isEmpty }
        guard !sampleSets.isEmpty else { return requestedKind }

        let extractor = MotionFeatureExtractor()
        let tokenizer = MotionTokenizer()
        let featuresList = sampleSets.map { extractor.extract($0) }
        var votes: [GestureKind: Double] = [:]

        for features in featuresList {
            let tokenKind = tokenizer.classify(features)
            let inferredKind: GestureKind
            let weight: Double
            switch tokenKind {
            case .rotation, .oscillation:
                inferredKind = .sequence
                weight = features.duration >= 0.8 ? 2.0 : 1.35
            case .hold:
                inferredKind = .posture
                weight = 1.8
            case .impulse, .sweep:
                inferredKind = .burst
                weight = 1.55
            case .pause, .free:
                inferredKind = features.duration <= 1.6 ? .burst : .sequence
                weight = 0.75
            }
            votes[inferredKind, default: 0] += weight
        }

        let averageDuration = featuresList.map(\.duration).reduce(0, +) / Double(featuresList.count)
        let hasSequenceEvidence = featuresList.contains { features in
            let tokenKind = tokenizer.classify(features)
            return tokenKind == .rotation
                || tokenKind == .oscillation
                || features.integratedRotationAngle >= .pi * 0.9
                || features.oscillationCount >= 2.0
        }

        if hasSequenceEvidence, averageDuration >= 0.65 {
            votes[.sequence, default: 0] += 1.2
        }
        if averageDuration > 1.8 {
            votes[.sequence, default: 0] += 0.8
        }

        return votes.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue < rhs.key.rawValue
            }
            return lhs.value < rhs.value
        }?.key ?? requestedKind
    }

    nonisolated private static func preparedTemplateSamples(
        _ samples: [MotionSample],
        requestedKind: GestureKind
    ) -> [MotionSample] {
        MotionSampleActivityTrimmer().trimForTemplate(samples, requestedKind: requestedKind)
    }

    nonisolated private static func preparedTemplate(
        from template: MotionTemplate,
        kind: GestureKind,
        builder: MotionTemplateBuilder
    ) -> MotionTemplate {
        let samples = preparedTemplateSamples(template.samples, requestedKind: kind)
        return builder.makeTemplate(label: template.label, kind: kind, samples: samples, createdAt: template.createdAt)
    }

    nonisolated private static func isLegacyUntitledProfile(_ profile: GestureProfile) -> Bool {
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("untitled") == .orderedSame
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
            ["sample", "positive", "negative", "debug", "watch"].contains(part.lowercased())
        }
        let role = roleIndex.map { parts[$0].lowercased() } ?? "unknown"
        let startIndex = min(2, parts.count)
        let endIndex = roleIndex.map { max(startIndex, $0) } ?? parts.count
        let gesture = parts[startIndex..<endIndex].joined(separator: "-")
        return (gesture.isEmpty ? "unknown" : gesture, role)
    }

    nonisolated private static func persistReceivedFile(
        sourceURL: URL,
        preferredFileName: String?,
        fileManager: FileManager = .default
    ) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("MotionSoundIncoming", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let preferredName = preferredFileName?.isEmpty == false
            ? preferredFileName!
            : sourceURL.lastPathComponent
        let destination = nonisolatedAvailableDestinationURL(
            directory: directory,
            fileName: nonisolatedSanitizeFileName(preferredName),
            fileManager: fileManager
        )

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: sourceURL, to: destination)
        return destination
    }

    nonisolated private static func nonisolatedAvailableDestinationURL(
        directory: URL,
        fileName: String,
        fileManager: FileManager
    ) -> URL {
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

    nonisolated private static func nonisolatedSanitizeFileName(_ value: String) -> String {
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
                _ = sendDiagnosticsConfiguration(reason: "activationComplete")
                _ = requestWatchRuntime(reason: "activationComplete")
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fileURL = file.fileURL
        let preferredFileName = file.metadata?["fileName"] as? String
        do {
            let destination = try Self.persistReceivedFile(sourceURL: fileURL, preferredFileName: preferredFileName)
            Task { @MainActor in
                finishReceivedFile(destination)
            }
        } catch {
            Task { @MainActor in
                lastMessage = error.localizedDescription
                AppDiagnostics.record(
                    error: error,
                    event: "phone.connectivity.receiveFile.error",
                    ["file": preferredFileName ?? fileURL.lastPathComponent]
                )
            }
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
        let profile = message["profile"] as? String
        let volume = message["volume"] as? Double
        var watchEventFileName: String?
        var watchEventError: String?
        if command == "watchRecognitionEvent" {
            do {
                watchEventFileName = try Self.persistWatchRecognitionEvent(message)
            } catch {
                watchEventError = error.localizedDescription
            }
        }
        Task { @MainActor in
            if command == "watchRecognitionEvent" {
                if let watchEventFileName {
                    noteWatchEventSaved(fileName: watchEventFileName)
                    reloadWatchEventCount()
                } else {
                    AppDiagnostics.record("phone.watchEvent.receive.error", ["error": watchEventError ?? "unknown"])
                }
                return
            }
            if command == "playSound" {
                receivePlaySound(command: command, fileName: fileName, profile: profile, volume: volume)
                return
            }
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
        let profile = userInfo["profile"] as? String
        let volume = userInfo["volume"] as? Double
        var watchEventFileName: String?
        var watchEventError: String?
        if command == "watchRecognitionEvent" {
            do {
                watchEventFileName = try Self.persistWatchRecognitionEvent(userInfo)
            } catch {
                watchEventError = error.localizedDescription
            }
        }
        Task { @MainActor in
            if command == "watchRecognitionEvent" {
                if let watchEventFileName {
                    noteWatchEventSaved(fileName: watchEventFileName)
                    reloadWatchEventCount()
                } else {
                    AppDiagnostics.record("phone.watchEvent.receive.error", ["error": watchEventError ?? "unknown"])
                }
                return
            }
            if command == "playSound" {
                receivePlaySound(command: command, fileName: fileName, profile: profile, volume: volume)
                return
            }
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
