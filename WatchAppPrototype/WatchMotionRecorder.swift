import Foundation
import CoreMotion
import Combine
import WatchKit
#if canImport(MotionSoundCore)
import MotionSoundCore
#endif

@MainActor
final class WatchMotionRecorder: ObservableObject {
    @Published private(set) var latestSample: MotionSample?
    @Published private(set) var samples: [MotionSample] = []
    @Published private(set) var isLive = false
    @Published private(set) var isRecording = false
    @Published private(set) var estimatedSampleRate: Double = 0
    @Published private(set) var lastAssessment: RecordingAssessment?
    @Published private(set) var lastRecordingQualityReport: RecordingQualityReport?
    @Published private(set) var lastSegment: GestureSegment?
    @Published private(set) var savedProfileURL: URL?
    @Published private(set) var savedRecordingURL: URL?
    @Published private(set) var lastFeedbackSampleURL: URL?
    @Published private(set) var loadedProfileCount = 0
    @Published private(set) var isProfileLibraryReady = false
    @Published private(set) var activeProfileLibraryVersion = ""
    @Published private(set) var activeRecognitionProfileID: UUID?
    @Published private(set) var activeRecognitionProfileName: String?
    @Published private(set) var lastRecognitionEvent: GestureRecognitionEvent?
    @Published private(set) var lastRecognitionSummary: String?
    @Published private(set) var triggerCount = 0
    @Published private(set) var audioPlayedTriggerCount = 0
    @Published private(set) var audioMissingTriggerCount = 0
    @Published private(set) var lastTriggeredProfileName: String?
    @Published private(set) var lastTriggeredSound: SoundAsset?
    @Published private(set) var lastTriggerAudioPlayed = false
    @Published private(set) var lastTriggerDate: Date?
    @Published private(set) var lastBurstGateRejectionReason: BurstGateRejectionReason?
    @Published private(set) var lastFeedbackMessage: String?
    @Published private(set) var standardTemplateCount = 0
    @Published private(set) var standardNegativeTemplateCount = 0
    @Published private(set) var standardRequiredTemplateCount = 5
    @Published private(set) var standardQuality: GestureQuality?
    /// 本地动作库摘要，供 Watch 端动作选择 UI 使用。
    @Published private(set) var availableProfileSummaries: [WatchGestureProfileSummary] = []
    /// 非 nil 表示有一个挂起的激活选择（目标动作尚未同步到本地库）。
    @Published private(set) var pendingActiveProfileName: String?
    var recognitionEventSink: (([String: Any]) -> Void)?
    /// 激活命令执行结果回执（applied / pending），由界面层接到 fileSender。
    var activeProfileAckSink: ((ActiveProfileSyncAck) -> Void)?
    /// Watch 本地切换动作后向 iPhone 推送的最新状态。
    var activeProfileStateSink: ((ActiveProfileSyncState) -> Void)?

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let validator = MotionRecordingValidator()
    private let templateBuilder = MotionTemplateBuilder()
    private let profileBuilder = GestureProfileBuilder()
    private let feedbackEngine = GestureFeedbackEngine()
    private let soundPlayer: WatchSoundPlayer?
    private let runtimeActor = MotionRuntimeActor()
    private var recognitionRuntime = GestureRecognitionRuntime(activeRecognitionSelection: .inactive)
    private var standardTemplates: [MotionTemplate] = []
    private var standardNegativeTemplates: [MotionTemplate] = []
    private var standardLabel: String?
    private var standardKind: GestureKind?
    private var triggerCountsByProfileID: [UUID: Int] = [:]
    private var lastNoProfileSummaryLogAt: TimeInterval = -.infinity
    private var lastNonCandidateTraceAt: TimeInterval = -.infinity
    private var motionCallbackCount = 0
    private var motionStartDiagnosticTask: Task<Void, Never>?
    private var lastRecordingAssessmentAt: TimeInterval = -.infinity
    /// 期望的激活选择（持久化，跨重启恢复；目标动作未同步到库时挂起等待）。
    private var desiredActiveSelection: ActiveProfileSyncState?

    init(soundPlayer: WatchSoundPlayer? = nil) {
        self.soundPlayer = soundPlayer
        motionQueue.name = "watch.motion.sound.core-motion"
        motionQueue.qualityOfService = .userInitiated
        desiredActiveSelection = WatchActiveProfileSelectionStore.load()
        AppDiagnostics.record(
            "watch.motionRecorder.init",
            [
                "restoredSelectionRevision": desiredActiveSelection?.revision ?? -1,
                "restoredSelectionProfile": desiredActiveSelection?.profileName ?? "",
            ]
        )
    }

    func startLiveUpdates(sampleRate: Double = 50) {
        AppDiagnostics.record(
            "watch.motion.startLiveUpdates.request",
            [
                "sampleRate": sampleRate,
                "deviceMotionAvailable": motionManager.isDeviceMotionAvailable,
                "accelerometerAvailable": motionManager.isAccelerometerAvailable,
                "gyroAvailable": motionManager.isGyroAvailable,
                "deviceMotionActive": motionManager.isDeviceMotionActive,
            ]
        )
        guard motionManager.isDeviceMotionAvailable else {
            AppDiagnostics.record("watch.motion.unavailable")
            return
        }
        guard !isLive else {
            AppDiagnostics.record("watch.motion.startLiveUpdates.skipped", ["reason": "alreadyLive"])
            return
        }

        motionManager.deviceMotionUpdateInterval = 1 / sampleRate
        let runtimeActor = runtimeActor
        Task { await runtimeActor.configure(nominalSampleInterval: 1 / sampleRate) }
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            if let error {
                AppDiagnostics.record(error: error, event: "watch.motion.callback.error")
                return
            }
            guard let motion else {
                AppDiagnostics.record("watch.motion.callback.empty")
                return
            }
            let rawSample = RawMotionSample(motion)
            Task { [weak self] in
                let output = await runtimeActor.ingest(rawSample)
                guard output.hasMainActorWork else { return }
                await MainActor.run {
                    self?.applyRuntimeOutput(output)
                }
            }
        }

        isLive = true
        scheduleMotionCallbackDiagnostic(previousCount: motionCallbackCount)
        AppDiagnostics.record(
            "watch.motion.startLiveUpdates",
            [
                "sampleRate": sampleRate,
                "deviceMotionActive": motionManager.isDeviceMotionActive,
            ]
        )
    }

    func stopLiveUpdates() {
        motionStartDiagnosticTask?.cancel()
        motionStartDiagnosticTask = nil
        motionManager.stopDeviceMotionUpdates()
        isLive = false
        isRecording = false
        lastRecordingAssessmentAt = -.infinity
        Task { await runtimeActor.stop() }
        AppDiagnostics.record("watch.motion.stopLiveUpdates")
    }

    func startRecording() {
        samples.removeAll(keepingCapacity: true)
        lastAssessment = nil
        lastRecordingAssessmentAt = -.infinity
        estimatedSampleRate = 0
        lastSegment = nil
        savedProfileURL = nil
        savedRecordingURL = nil
        let recognitionSuppressedUntil = (latestSample?.timestamp ?? 0) + 30
        lastRecognitionSummary = "录制中，已暂停动作触发。"
        isRecording = true
        Task { await runtimeActor.startRecording() }
        if !isLive {
            startLiveUpdates()
        }
        AppDiagnostics.record(
            "watch.recording.start",
            ["recognitionSuppressedUntil": recognitionSuppressedUntil]
        )
    }

    func reloadSavedProfiles() {
        do {
            let store = try GestureProfileFileStore.appDocumentsStore()
            let profiles = deduplicateProfiles(try store.list().flatMap(\.archive.profiles))
            recognitionRuntime.replaceProfiles(profiles)
            Task { await runtimeActor.replaceProfiles(profiles) }
            availableProfileSummaries = profiles.map {
                WatchGestureProfileSummary(id: $0.id, name: $0.name, kind: $0.kind)
            }
            resolveDesiredSelection(reason: "reloadSavedProfiles")
            triggerCountsByProfileID = triggerCountsByProfileID.filter { id, _ in
                profiles.contains { $0.id == id }
            }
            soundPlayer?.preload(profileSounds: profiles)
            loadedProfileCount = profiles.count
            if isProfileLibraryReady, pendingActiveProfileName == nil {
                lastFeedbackMessage = nil
            }
            AppDiagnostics.record(
                "watch.profiles.reload",
                [
                    "count": profiles.count,
                    "profileLibraryReady": isProfileLibraryReady,
                    "profileLibraryVersion": activeProfileLibraryVersion,
                    "activeProfileID": activeRecognitionProfileID?.uuidString ?? "",
                    "activeProfileName": activeRecognitionProfileName ?? "",
                    "pendingSelection": pendingActiveProfileName ?? "",
                ]
            )
        } catch {
            loadedProfileCount = 0
            availableProfileSummaries = []
            // 加载失败只停用识别，不抹掉用户的期望选择；下次加载成功后自动恢复。
            deactivateRecognition(reason: "reloadSavedProfiles.error")
            lastFeedbackMessage = error.localizedDescription
            Task { await runtimeActor.replaceProfiles([]) }
            AppDiagnostics.record(error: error, event: "watch.profiles.reload.error")
        }
    }

    /// 处理来自 iPhone 的激活命令（sendMessage / userInfo / applicationContext）。
    func applyRemoteActiveSelection(_ command: ActiveProfileSelectionCommand) {
        let state = ActiveProfileSyncState(
            revision: command.revision ?? nextLocalSelectionRevision(),
            profileID: command.profileID,
            profileName: command.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: command.updatedAt ?? Date(),
            origin: command.origin ?? "phone"
        )
        adoptDesiredSelection(state, reason: command.reason ?? "phoneCommand", notifyPhone: false)
    }

    /// Watch 端本地切换当前动作（profileID 为 nil 表示关闭识别）。
    func selectActiveProfileLocally(profileID: UUID?, reason: String) {
        let profile = profileID.flatMap { id in
            recognitionRuntime.profiles.first { $0.id == id }
        }
        let state = ActiveProfileSyncState(
            revision: nextLocalSelectionRevision(),
            profileID: profile?.id ?? profileID,
            profileName: profile?.name,
            origin: "watch"
        )
        adoptDesiredSelection(state, reason: reason, notifyPhone: true)
    }

    private func nextLocalSelectionRevision() -> Int {
        (desiredActiveSelection?.revision ?? 0) + 1
    }

    private func adoptDesiredSelection(_ state: ActiveProfileSyncState, reason: String, notifyPhone: Bool) {
        guard state.supersedes(desiredActiveSelection) else {
            // 乱序送达的旧命令：忽略，但重发一次当前状态的回执，让 iPhone 收敛。
            AppDiagnostics.record(
                "watch.activeProfile.staleCommandIgnored",
                [
                    "incomingRevision": state.revision,
                    "currentRevision": desiredActiveSelection?.revision ?? -1,
                    "reason": reason,
                ]
            )
            sendSelectionAck(
                applied: activeRecognitionProfileID != nil || isDesiredSelectionEmpty,
                pending: pendingActiveProfileName != nil,
                reason: "staleCommandIgnored"
            )
            return
        }
        desiredActiveSelection = state
        WatchActiveProfileSelectionStore.save(state)
        if notifyPhone {
            activeProfileStateSink?(state)
        }
        resolveDesiredSelection(reason: reason)
    }

    /// 尝试把期望选择落到识别运行时上：
    /// 找到目标动作 → 激活；目标是"未选择" → 关闭识别；
    /// 找不到目标动作 → 挂起等待（库同步完成后由 reloadSavedProfiles 重放）。
    private func resolveDesiredSelection(reason: String) {
        guard let desired = desiredActiveSelection else {
            pendingActiveProfileName = nil
            deactivateRecognition(reason: "noSelection.\(reason)")
            return
        }

        guard !isDesiredSelectionEmpty else {
            pendingActiveProfileName = nil
            deactivateRecognition(reason: "clearedSelection.\(reason)")
            sendSelectionAck(applied: true, pending: false, reason: reason)
            return
        }

        if let profile = findProfile(id: desired.profileID, name: desired.profileName) {
            applyActiveRecognitionProfile(profile, reason: reason)
            pendingActiveProfileName = nil
            sendSelectionAck(applied: true, pending: false, reason: reason)
            return
        }

        // 目标动作不在本地库：可能库尚未同步完、动作文件还在传输、或动作已被删除。
        // 保守处理：保留期望选择并挂起，识别保持关闭；
        // "动作被删除"的场景由 iPhone 端显式发送清空命令来收敛。
        pendingActiveProfileName = desired.profileName ?? desired.profileID?.uuidString
        deactivateRecognition(reason: "pending.\(reason)")
        lastFeedbackMessage = "等待动作同步：\(pendingActiveProfileName ?? "")"
        sendSelectionAck(
            applied: false,
            pending: true,
            reason: isProfileLibraryReady ? "profileNotInLibrary" : "libraryNotReady"
        )
        AppDiagnostics.record(
            "watch.activeProfile.pending",
            [
                "profileID": desired.profileID?.uuidString ?? "",
                "name": desired.profileName ?? "",
                "revision": desired.revision,
                "profileLibraryReady": isProfileLibraryReady,
                "loadedProfileCount": loadedProfileCount,
                "reason": reason,
            ]
        )
    }

    private var isDesiredSelectionEmpty: Bool {
        guard let desired = desiredActiveSelection else { return true }
        return desired.profileID == nil && (desired.profileName?.isEmpty ?? true)
    }

    private func findProfile(id: UUID?, name: String?) -> GestureProfile? {
        if let id, let profile = recognitionRuntime.profiles.first(where: { $0.id == id }) {
            return profile
        }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return recognitionRuntime.profiles.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func deactivateRecognition(reason: String) {
        activeRecognitionProfileID = nil
        activeRecognitionProfileName = nil
        recognitionRuntime.setActiveProfileIDs([])
        Task { await runtimeActor.setActiveProfileIDs([]) }
        AppDiagnostics.record("watch.activeProfile.deactivated", ["reason": reason])
    }

    private func applyActiveRecognitionProfile(_ profile: GestureProfile, reason: String) {
        activeRecognitionProfileID = profile.id
        activeRecognitionProfileName = profile.name
        recognitionRuntime.setActiveProfileIDs([profile.id])
        Task { await runtimeActor.setActiveProfileIDs([profile.id]) }
        lastFeedbackMessage = nil
        AppDiagnostics.record(
            "watch.activeProfile.set",
            [
                "profileID": profile.id.uuidString,
                "name": profile.name,
                "reason": reason,
            ]
        )
    }

    private func sendSelectionAck(applied: Bool, pending: Bool, reason: String?) {
        guard let desired = desiredActiveSelection else { return }
        let ack = ActiveProfileSyncAck(
            revision: desired.revision,
            profileID: desired.profileID,
            profileName: desired.profileName,
            applied: applied,
            pending: pending,
            reason: reason
        )
        activeProfileAckSink?(ack)
    }

    func updateProfileLibraryState(
        isReady: Bool,
        version: String?,
        expectedProfileCount: Int,
        reason: String
    ) {
        isProfileLibraryReady = isReady
        activeProfileLibraryVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isReady {
            lastFeedbackMessage = expectedProfileCount > 0 ? nil : "动作库为空，请在 iPhone 创建动作。"
        } else {
            lastFeedbackMessage = "等待 iPhone 同步动作库。"
            recognitionRuntime.resetRuntimeState()
            Task { await runtimeActor.resetRuntimeState() }
        }
        Task {
            await runtimeActor.updateProfileLibraryState(
                isReady: isReady,
                version: activeProfileLibraryVersion,
                expectedProfileCount: expectedProfileCount
            )
        }
        AppDiagnostics.record(
            "watch.profileLibrary.state",
            [
                "ready": isReady,
                "profileLibraryVersion": activeProfileLibraryVersion,
                "expectedProfileCount": expectedProfileCount,
                "loadedProfileCount": loadedProfileCount,
                "reason": reason,
            ]
        )
    }

    private func deduplicateProfiles(_ profiles: [GestureProfile]) -> [GestureProfile] {
        var seenIDs: Set<UUID> = []
        var seenNames: Set<String> = []
        var output: [GestureProfile] = []
        output.reserveCapacity(profiles.count)

        for profile in profiles {
            let normalizedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !seenIDs.contains(profile.id), !seenNames.contains(normalizedName) else {
                continue
            }
            seenIDs.insert(profile.id)
            seenNames.insert(normalizedName)
            output.append(profile)
        }

        return output
    }

    func markLastTriggerAsFalse() {
        guard let event = lastRecognitionEvent, event.triggered else {
            lastFeedbackMessage = "没有可反馈的触发事件"
            return
        }

        do {
            let updatedProfiles = feedbackEngine.applyFalseTrigger(
                event: event,
                to: recognitionRuntime.profiles
            )
            lastFeedbackSampleURL = try persistFeedbackSample(
                role: "false-trigger",
                profile: event.profile,
                segment: event.segment,
                metadata: [
                    "feedback": "false-trigger",
                    "triggeredProfileID": event.profile?.id.uuidString ?? "",
                    "triggeredProfileName": event.profile?.name ?? "",
                    "rejectReason": event.logEntry.rejectReason?.rawValue ?? "",
                ]
            )
            let archive = GestureProfileArchive(profiles: updatedProfiles)
            let store = try GestureProfileFileStore.appDocumentsStore()
            _ = try store.save(archive, preferredName: "feedback-updated-profiles")
            recognitionRuntime.replaceProfiles(updatedProfiles)
            Task { await runtimeActor.replaceProfiles(updatedProfiles) }
            loadedProfileCount = updatedProfiles.count
            lastFeedbackMessage = "已记录误触反馈并更新阈值"
            AppDiagnostics.record("watch.feedback.falseTriggerApplied", ["profileCount": updatedProfiles.count])
        } catch {
            lastFeedbackMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.feedback.falseTrigger.error")
        }
    }

    func markRecentMotionAsMissed(profileID: UUID? = nil, name: String? = nil) {
        let profile = recognitionRuntime.profiles.first { profile in
            if let profileID, profile.id == profileID {
                return true
            }
            if let name {
                return profile.name.caseInsensitiveCompare(name) == .orderedSame
            }
            return profile.id == activeRecognitionProfileID
        }
        guard let profile else {
            lastFeedbackMessage = "没有找到漏触对应动作"
            return
        }
        guard let segment = lastSegment else {
            lastFeedbackMessage = "没有可归档的最近动作片段"
            return
        }
        do {
            lastFeedbackSampleURL = try persistFeedbackSample(
                role: "missed",
                profile: profile,
                segment: segment,
                metadata: [
                    "feedback": "missed",
                    "targetProfileID": profile.id.uuidString,
                    "targetProfileName": profile.name,
                ]
            )
            lastFeedbackMessage = "已保存漏触候选样本"
            AppDiagnostics.record(
                "watch.feedback.missedArchived",
                ["profileID": profile.id.uuidString, "profileName": profile.name]
            )
        } catch {
            lastFeedbackMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.feedback.missed.error")
        }
    }

    func stopRecording() -> [MotionSample] {
        isRecording = false
        lastAssessment = validator.assess(samples)
        let recognitionSuppressedUntil = (latestSample?.timestamp ?? 0) + 1.25
        Task { await runtimeActor.stopRecording() }
        AppDiagnostics.record(
            "watch.recording.stop",
            [
                "samples": samples.count,
                "duration": lastAssessment?.duration ?? 0,
                "sampleRate": lastAssessment?.estimatedSampleRate ?? 0,
                "recognitionSuppressedUntil": recognitionSuppressedUntil,
            ]
        )
        return samples
    }

    func exportRecordingJSON(label: String, kind: GestureKind) throws -> Data {
        let template = templateBuilder.makeTemplate(
            label: label,
            kind: kind,
            samples: samples,
        )
        return try JSONEncoder.motionSound.encode(template)
    }

    func exportRecordingCSV() throws -> String {
        guard !samples.isEmpty else {
            throw WatchMotionRecorderError.noSamples
        }
        return MotionSampleCSVCodec().encode(samples)
    }

    func saveRecordingCSV(label: String) throws -> URL {
        guard !samples.isEmpty else {
            throw WatchMotionRecorderError.noSamples
        }
        let store = try MotionRecordingFileStore.appDocumentsStore()
        let url = try store.save(samples, preferredName: label)
        savedRecordingURL = url
        AppDiagnostics.record("watch.recording.saveCSV", ["file": url.lastPathComponent, "samples": samples.count])
        return url
    }

    func exportQuickProfileJSON(label: String, kind: GestureKind, soundFileName: String? = nil) throws -> Data {
        let archive = try makeQuickProfileArchive(label: label, kind: kind, soundFileName: soundFileName)
        return try JSONEncoder.motionSound.encode(archive)
    }

    func saveQuickProfile(label: String, kind: GestureKind, soundFileName: String? = nil) throws -> URL {
        let archive = try makeQuickProfileArchive(label: label, kind: kind, soundFileName: soundFileName)
        let store = try GestureProfileFileStore.appDocumentsStore()
        let url = try store.save(archive, preferredName: label)
        savedProfileURL = url
        reloadSavedProfiles()
        AppDiagnostics.record("watch.profile.saveQuick", ["file": url.lastPathComponent, "label": label])
        return url
    }

    func resetStandardProfileDraft() {
        standardTemplates.removeAll(keepingCapacity: true)
        standardNegativeTemplates.removeAll(keepingCapacity: true)
        standardLabel = nil
        standardKind = nil
        standardTemplateCount = 0
        standardNegativeTemplateCount = 0
        standardQuality = nil
        lastFeedbackMessage = nil
        lastRecordingQualityReport = nil
    }

    @discardableResult
    func addCurrentRecordingToStandardProfile(label: String, kind: GestureKind) throws -> Int {
        guard !samples.isEmpty else {
            throw WatchMotionRecorderError.noSamples
        }

        let trimmedLabel = normalizedLabel(label)
        try setStandardDraftIdentity(label: trimmedLabel, kind: kind)

        let qualityReport = validator.qualityReport(
            samples: samples,
            draftKind: kind,
            existingPositiveTemplates: standardTemplates,
            existingNegativeTemplates: standardNegativeTemplates
        )
        lastRecordingQualityReport = qualityReport
        guard qualityReport.canUseForTraining else {
            throw WatchMotionRecorderError.recordingQualityRejected(
                message: qualityReport.errors.first ?? qualityReport.warnings.first ?? "这次录制质量不足，请重录"
            )
        }

        let template = templateBuilder.makeTemplate(
            label: trimmedLabel,
            kind: kind,
            samples: samples
        )
        standardTemplates.append(template)
        standardTemplateCount = standardTemplates.count
        refreshStandardQuality()
        lastFeedbackMessage = "已加入校准样本 \(standardTemplateCount)/\(standardRequiredTemplateCount)"
        return standardTemplateCount
    }

    @discardableResult
    func addCurrentRecordingAsStandardNegative(label: String, kind: GestureKind) throws -> Int {
        guard !samples.isEmpty else {
            throw WatchMotionRecorderError.noSamples
        }

        let trimmedLabel = normalizedLabel(label)
        try setStandardDraftIdentity(label: trimmedLabel, kind: kind)

        let template = templateBuilder.makeTemplate(
            label: "\(trimmedLabel)-negative",
            kind: kind,
            samples: samples
        )
        standardNegativeTemplates.append(template)
        standardNegativeTemplateCount = standardNegativeTemplates.count
        refreshStandardQuality()
        lastFeedbackMessage = "已记录误触反馈 \(standardNegativeTemplateCount)"
        return standardNegativeTemplateCount
    }

    func exportStandardProfileJSON(label: String, kind: GestureKind, soundFileName: String? = nil) throws -> Data {
        let archive = try makeStandardProfileArchive(label: label, kind: kind, soundFileName: soundFileName)
        return try JSONEncoder.motionSound.encode(archive)
    }

    func saveStandardProfile(label: String, kind: GestureKind, soundFileName: String? = nil) throws -> URL {
        let archive = try makeStandardProfileArchive(label: label, kind: kind, soundFileName: soundFileName)
        let store = try GestureProfileFileStore.appDocumentsStore()
        let url = try store.save(archive, preferredName: label)
        savedProfileURL = url
        reloadSavedProfiles()
        AppDiagnostics.record("watch.profile.saveStandard", ["file": url.lastPathComponent, "label": label])
        return url
    }

    private func makeQuickProfileArchive(
        label: String,
        kind: GestureKind,
        soundFileName: String? = nil
    ) throws -> GestureProfileArchive {
        guard !samples.isEmpty else {
            throw WatchMotionRecorderError.noSamples
        }

        let qualityReport = validator.qualityReport(samples: samples, draftKind: kind)
        lastRecordingQualityReport = qualityReport
        guard qualityReport.canUseForTraining else {
            throw WatchMotionRecorderError.recordingQualityRejected(
                message: qualityReport.errors.first ?? qualityReport.warnings.first ?? "这次录制质量不足，请重录"
            )
        }

        let template = templateBuilder.makeTemplate(label: label, kind: kind, samples: samples)
        let sound = normalizedSoundAsset(fileName: soundFileName)
        let profile = profileBuilder.makeProfile(
            name: label,
            kind: kind,
            templates: [template],
            sound: sound,
            wearContext: currentWearContext()
        )
        return GestureProfileArchive(profiles: [profile])
    }

    private func makeStandardProfileArchive(
        label: String,
        kind: GestureKind,
        soundFileName: String? = nil
    ) throws -> GestureProfileArchive {
        guard standardTemplates.count >= standardRequiredTemplateCount else {
            throw WatchMotionRecorderError.insufficientStandardTemplates(
                current: standardTemplates.count,
                required: standardRequiredTemplateCount
            )
        }

        let trimmedLabel = normalizedLabel(label)
        guard standardLabel == trimmedLabel, standardKind == kind else {
            throw WatchMotionRecorderError.standardDraftMismatch(
                expected: "\(standardLabel ?? "-") / \(standardKind?.rawValue ?? "-")"
            )
        }

        let sound = normalizedSoundAsset(fileName: soundFileName)
        let profile = profileBuilder.makeProfile(
            name: trimmedLabel,
            kind: kind,
            templates: standardTemplates,
            negativeTemplates: standardNegativeTemplates,
            sound: sound,
            wearContext: currentWearContext(),
            existingProfiles: recognitionRuntime.profiles
        )
        return GestureProfileArchive(profiles: [profile])
    }

    private func setStandardDraftIdentity(label: String, kind: GestureKind) throws {
        if let standardLabel, standardLabel != label {
            throw WatchMotionRecorderError.standardDraftMismatch(
                expected: "\(standardLabel) / \(standardKind?.rawValue ?? "-")"
            )
        }
        if let standardKind, standardKind != kind {
            throw WatchMotionRecorderError.standardDraftMismatch(
                expected: "\(standardLabel ?? "-") / \(standardKind.rawValue)"
            )
        }

        standardLabel = label
        standardKind = kind
    }

    private func refreshStandardQuality() {
        standardQuality = GestureQualityEvaluator()
            .evaluate(
                templates: standardTemplates,
                negativeTemplates: standardNegativeTemplates,
                existingProfiles: recognitionRuntime.profiles
            )
            .quality
    }

    private func normalizedLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gesture" : trimmed
    }

    private func normalizedSoundAsset(fileName: String?) -> SoundAsset? {
        guard let fileName else { return nil }
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SoundAsset(fileName: trimmed, duration: 0)
    }

    private func currentWearContext() -> WearContext {
        WearContext(
            wristLocation: WKInterfaceDevice.current().wristLocation == .left ? "left" : "right",
            crownOrientation: WKInterfaceDevice.current().crownOrientation == .left ? "left" : "right",
            watchModel: WKInterfaceDevice.current().model,
            osVersion: WKInterfaceDevice.current().systemVersion
        )
    }

    private func applyRuntimeOutput(_ output: MotionRuntimeOutput) {
        if let motionCallbackCount = output.motionCallbackCount {
            self.motionCallbackCount = motionCallbackCount
        }
        if let latestSample = output.latestSample {
            self.latestSample = latestSample
        }
        if let recordingSample = output.recordingSample {
            samples.append(recordingSample)
            updateRecordingAssessmentIfNeeded(sample: recordingSample)
        }
        if let recognition = output.recognition {
            processRecognition(
                segment: recognition.segment,
                evaluation: recognition.evaluation,
                liveSample: recognition.liveSample,
                source: recognition.source,
                recognitionMs: recognition.recognitionMs
            )
        }
    }

    private func updateRecordingAssessmentIfNeeded(sample: MotionSample) {
        guard sample.timestamp - lastRecordingAssessmentAt >= 0.25 else { return }
        lastRecordingAssessmentAt = sample.timestamp
        lastAssessment = validator.assess(samples)
        if let standardKind {
            lastRecordingQualityReport = validator.qualityReport(
                samples: samples,
                draftKind: standardKind,
                existingPositiveTemplates: standardTemplates,
                existingNegativeTemplates: standardNegativeTemplates
            )
        }
        estimatedSampleRate = lastAssessment?.estimatedSampleRate ?? 0
    }

    private func processRecognition(
        segment: GestureSegment,
        evaluation: RecognitionEvaluation,
        liveSample: MotionSample,
        source: String,
        recognitionMs: Double
    ) {
        lastSegment = segment
        AppDiagnostics.record(
            "watch.motion.segment",
            [
                "source": source,
                "kind": segment.kind.rawValue,
                "duration": segment.duration,
                "peakEnergy": segment.peakEnergy,
            ]
        )

        let candidate = evaluation.candidate
        let rejectReason = evaluation.rejectReason

        lastBurstGateRejectionReason = evaluation.burstGateRejectionReason
        updateRecognitionSummary(segment: segment, candidate: candidate, rejectionReason: evaluation.burstGateRejectionReason)
        let soundToPlay = candidate?.shouldTrigger == true ? nextSound(for: candidate?.profile) : nil
        let audioReady = soundToPlay.flatMap { soundPlayer?.canPlay(sound: $0) } ?? false
        let audioPlayRequested = candidate?.shouldTrigger == true
            ? (soundPlayer?.play(sound: soundToPlay) ?? false)
            : false
        let audioPlayed = audioPlayRequested && (soundPlayer?.lastAudiblePlaySucceeded ?? audioPlayRequested)
        let audioStartLatencyMs = candidate?.shouldTrigger == true
            ? max(0, liveSample.timestamp - segment.peakTimestamp) * 1000
            : nil
        lastRecognitionEvent = recognitionRuntime.record(
            segment: segment,
            candidate: candidate,
            now: liveSample.timestamp,
            wearContext: currentWearContext(),
            audioPlayed: audioPlayed,
            burstGateRejectionReason: evaluation.burstGateRejectionReason,
            tokens: evaluation.tokens,
            classifiedKind: evaluation.classifiedKind,
            candidateReports: evaluation.candidateReports,
            rejectReason: rejectReason
        )
        if lastRecognitionEvent?.triggered == true {
            if let profile = lastRecognitionEvent?.profile {
                triggerCountsByProfileID[profile.id, default: 0] += 1
            }
            triggerCount += 1
            if audioPlayed {
                audioPlayedTriggerCount += 1
            } else {
                audioMissingTriggerCount += 1
            }
            lastTriggeredProfileName = lastRecognitionEvent?.profile?.name
            lastTriggeredSound = soundToPlay
            lastTriggerAudioPlayed = audioPlayed
            lastTriggerDate = Date()
            WKInterfaceDevice.current().play(.success)
            AppDiagnostics.record(
                "watch.recognition.triggered",
                [
                    "source": source,
                    "profile": lastRecognitionEvent?.profile?.name ?? "",
                    "audioPlayed": audioPlayed,
                    "audioPlayRequested": audioPlayRequested,
                    "audioReady": audioReady,
                    "audioStartLatencyMs": audioStartLatencyMs ?? -1,
                    "recognitionMs": recognitionMs,
                    "triggerTiming": lastRecognitionEvent?.profile?.triggerTiming.rawValue ?? "",
                    "sound": soundToPlay?.fileName ?? "",
                    "profileTriggerCount": lastRecognitionEvent?.profile.map { triggerCountsByProfileID[$0.id, default: 0] } ?? 0,
                    "triggerCount": triggerCount,
                    "audioPlayedTriggerCount": audioPlayedTriggerCount,
                    "audioMissingTriggerCount": audioMissingTriggerCount,
                ]
            )
            AppDiagnostics.record(
                "watch.recognition.triggerHaptic",
                ["profile": lastRecognitionEvent?.profile?.name ?? ""]
            )
        }
        persistRecognitionTraceIfNeeded(
            segment: segment,
            candidate: candidate,
            rejectionReason: evaluation.burstGateRejectionReason,
            rejectReason: rejectReason,
            tokens: evaluation.tokens,
            classifiedKind: evaluation.classifiedKind,
            candidateReports: evaluation.candidateReports,
            audioPlayed: audioPlayed,
            audioReady: audioReady,
            recognitionMs: recognitionMs,
            audioStartLatencyMs: audioStartLatencyMs,
            triggered: lastRecognitionEvent?.triggered == true
        )
    }

    private func scheduleMotionCallbackDiagnostic(previousCount: Int) {
        motionStartDiagnosticTask?.cancel()
        motionStartDiagnosticTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, isLive else { return }
            if motionCallbackCount == previousCount {
                AppDiagnostics.record(
                    "watch.motion.noCallbacksAfterStart",
                    [
                        "deviceMotionActive": motionManager.isDeviceMotionActive,
                        "deviceMotionAvailable": motionManager.isDeviceMotionAvailable,
                    ]
                )
            } else {
                AppDiagnostics.record(
                    "watch.motion.callbacksAfterStart",
                    [
                        "count": motionCallbackCount - previousCount,
                        "total": motionCallbackCount,
                    ]
                )
            }
        }
    }

    private func persistRecognitionTraceIfNeeded(
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        rejectionReason: BurstGateRejectionReason?,
        rejectReason: RejectReason?,
        tokens: [MotionToken],
        classifiedKind: MotionTokenKind?,
        candidateReports: [CandidateRecognitionReport],
        audioPlayed: Bool,
        audioReady: Bool,
        recognitionMs: Double,
        audioStartLatencyMs: Double?,
        triggered: Bool
    ) {
        guard shouldPersistRecognitionTrace(
            segment: segment,
            candidate: candidate,
            rejectionReason: rejectionReason,
            triggered: triggered
        ) else {
            return
        }

        do {
            let directory = try recognitionTraceDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let now = Date()
            let baseName = recognitionTraceBaseName(
                date: now,
                outcome: recognitionOutcome(triggered: triggered, candidate: candidate, rejectionReason: rejectionReason),
                profileName: candidate?.profile.name
            )
            let csvURL = directory.appendingPathComponent("\(baseName).csv")
            let jsonURL = directory.appendingPathComponent("\(baseName).json")

            try MotionSecureFileWriter.write(MotionSampleCSVCodec().encodeData(segment.samples), to: csvURL)
            let metadata = recognitionTraceMetadata(
                date: now,
                segment: segment,
                candidate: candidate,
                rejectionReason: rejectionReason,
                rejectReason: rejectReason,
                tokens: tokens,
                classifiedKind: classifiedKind,
                candidateReports: candidateReports,
                audioPlayed: audioPlayed,
                audioReady: audioReady,
                recognitionMs: recognitionMs,
                audioStartLatencyMs: audioStartLatencyMs,
                triggered: triggered,
                csvFileName: csvURL.lastPathComponent
            )
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try MotionSecureFileWriter.write(data, to: jsonURL)
            recognitionEventSink?(compactRecognitionEventMetadata(
                date: now,
                segment: segment,
                candidate: candidate,
                rejectionReason: rejectionReason,
                rejectReason: rejectReason,
                tokens: tokens,
                classifiedKind: classifiedKind,
                candidateReports: candidateReports,
                audioPlayed: audioPlayed,
                audioReady: audioReady,
                recognitionMs: recognitionMs,
                audioStartLatencyMs: audioStartLatencyMs,
                triggered: triggered,
                csvFileName: csvURL.lastPathComponent,
                jsonFileName: jsonURL.lastPathComponent
            ))
            pruneRecognitionTraceDirectory(directory, keepingNewestFilePairs: 80)
            AppDiagnostics.record(
                "watch.recognition.traceSaved",
                [
                    "csv": csvURL.lastPathComponent,
                    "metadata": jsonURL.lastPathComponent,
                    "samples": segment.samples.count,
                    "triggered": triggered,
                    "profile": candidate?.profile.name ?? "",
                ]
            )
        } catch {
            AppDiagnostics.record(error: error, event: "watch.recognition.traceSave.error")
        }
    }

    private func shouldPersistRecognitionTrace(
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        rejectionReason: BurstGateRejectionReason?,
        triggered: Bool
    ) -> Bool {
        if triggered || candidate != nil || rejectionReason != nil {
            return true
        }

        guard !recognitionRuntime.profiles.isEmpty else {
            return false
        }

        guard segment.endTimestamp - lastNonCandidateTraceAt >= 5 else {
            return false
        }
        lastNonCandidateTraceAt = segment.endTimestamp
        return true
    }

    private func nextSound(for profile: GestureProfile?) -> SoundAsset? {
        guard let profile else { return nil }
        let sequence = profile.soundSequence?.filter {
            !$0.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        guard !sequence.isEmpty else {
            return profile.sound
        }

        let currentCount = triggerCountsByProfileID[profile.id, default: 0]
        let index = min(currentCount, sequence.count - 1)
        return sequence[index]
    }

    private func recognitionTraceDirectory() throws -> URL {
        try AppDiagnostics.runDirectory()
            .appendingPathComponent("watchOS", isDirectory: true)
            .appendingPathComponent("trigger-traces", isDirectory: true)
    }

    private func recognitionTraceBaseName(date: Date, outcome: String, profileName: String?) -> String {
        let timestampFormatter = DateFormatter()
        timestampFormatter.calendar = Calendar(identifier: .gregorian)
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss-SSS"

        let profilePart = sanitizeTraceFileName(profileName ?? "no-profile")
        return "\(timestampFormatter.string(from: date))-\(outcome)-\(profilePart)"
    }

    private func persistFeedbackSample(
        role: String,
        profile: GestureProfile?,
        segment: GestureSegment,
        metadata: [String: String]
    ) throws -> URL {
        let now = Date()
        let profileName = profile?.name ?? "unknown-profile"
        let root = try MotionSecureFileWriter.applicationSupportSubdirectory("FeedbackSamples")
        let directory = root
            .appendingPathComponent(sanitizeTraceFileName(profileName), isDirectory: true)
            .appendingPathComponent(role, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = recognitionTraceBaseName(date: now, outcome: role, profileName: profileName)
        let csvURL = directory.appendingPathComponent("\(baseName).csv")
        let jsonURL = directory.appendingPathComponent("\(baseName).json")
        try MotionSecureFileWriter.write(MotionSampleCSVCodec().encodeData(segment.samples), to: csvURL)

        var payload: [String: Any] = metadata
        payload["schemaVersion"] = 1
        payload["role"] = role
        payload["csvFileName"] = csvURL.lastPathComponent
        payload["createdAt"] = ISO8601DateFormatter().string(from: now)
        payload["profileID"] = profile?.id.uuidString ?? ""
        payload["profileName"] = profileName
        payload["segmentDuration"] = segment.duration
        payload["sampleCount"] = segment.samples.count
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try MotionSecureFileWriter.write(data, to: jsonURL)
        return csvURL
    }

    private func recognitionOutcome(
        triggered: Bool,
        candidate: RecognitionCandidate?,
        rejectionReason: BurstGateRejectionReason?
    ) -> String {
        if recognitionRuntime.profiles.isEmpty {
            return "no-profiles"
        }
        if triggered {
            return "triggered"
        }
        if rejectionReason != nil {
            return "rejected"
        }
        if candidate == nil {
            return "no-candidate"
        }
        return "candidate-rejected"
    }

    private func recognitionTraceMetadata(
        date: Date,
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        rejectionReason: BurstGateRejectionReason?,
        rejectReason: RejectReason?,
        tokens: [MotionToken],
        classifiedKind: MotionTokenKind?,
        candidateReports: [CandidateRecognitionReport],
        audioPlayed: Bool,
        audioReady: Bool,
        recognitionMs: Double,
        audioStartLatencyMs: Double?,
        triggered: Bool,
        csvFileName: String
    ) -> [String: Any] {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var metadata: [String: Any] = [
            "schemaVersion": 2,
            "createdAt": timestampFormatter.string(from: date),
            "csvFileName": csvFileName,
            "source": "watchRecognitionTrace",
            "sampleRateHz": estimatedSampleRate,
            "outcome": recognitionOutcome(triggered: triggered, candidate: candidate, rejectionReason: rejectionReason),
            "triggered": triggered,
            "audioPlayed": audioPlayed,
            "audioReady": audioReady,
            "audioStartLatencyMs": audioStartLatencyMs ?? NSNull(),
            "recognitionMs": recognitionMs,
            "profileCount": recognitionRuntime.profiles.count,
            "profileLibraryReady": isProfileLibraryReady,
            "profileLibraryVersion": activeProfileLibraryVersion,
            "segmentKind": segment.kind.rawValue,
            "classifiedKind": classifiedKind?.rawValue ?? "",
            "sampleCount": segment.samples.count,
            "duration": segment.duration,
            "startTimestamp": segment.startTimestamp,
            "endTimestamp": segment.endTimestamp,
            "peakEnergy": segment.peakEnergy,
            "peakTimestamp": segment.peakTimestamp,
            "peakAcceleration": segment.features.peakAcceleration,
            "peakRotationRate": segment.features.peakRotationRate,
            "peakJerk": segment.features.peakJerk,
            "meanEnergy": segment.features.meanEnergy,
            "dominantAxis": segment.features.dominantAxis,
            "wearContext": [
                "wristLocation": currentWearContext().wristLocation,
                "crownOrientation": currentWearContext().crownOrientation,
                "watchModel": currentWearContext().watchModel ?? "",
                "osVersion": currentWearContext().osVersion ?? "",
            ],
        ]

        if let rejectionReason {
            metadata["rejectionReason"] = rejectionReason.rawValue
        }
        if let rejectReason {
            metadata["rejectReason"] = rejectReason.rawValue
        }
        metadata["tokens"] = tokens.map { token in
            [
                "kind": token.kind.rawValue,
                "startTime": token.startTime,
                "endTime": token.endTime,
                "duration": token.duration,
                "direction": token.direction,
                "magnitude": token.magnitude,
                "confidence": token.confidence,
                "mainAxis": [
                    "x": token.mainAxis.x,
                    "y": token.mainAxis.y,
                    "z": token.mainAxis.z,
                ],
                "peakAcc": token.peakAcc ?? NSNull(),
                "peakGyro": token.peakGyro ?? NSNull(),
                "integratedAngle": token.integratedAngle ?? NSNull(),
                "oscillationCount": token.oscillationCount ?? NSNull(),
                "holdStability": token.holdStability ?? NSNull(),
            ] as [String: Any]
        }
        metadata["candidateReports"] = candidateReports.map { report in
            [
                "profileID": report.profileID.uuidString,
                "profileName": report.profileName,
                "variantID": report.variantID?.uuidString ?? "",
                "variantLabel": report.variantLabel ?? "",
                "recognizerKind": report.recognizerKind.rawValue,
                "score": report.score,
                "threshold": report.threshold,
                "margin": report.margin ?? NSNull(),
                "shouldTrigger": report.shouldTrigger,
                "rejectReason": report.rejectReason?.rawValue ?? "",
            ] as [String: Any]
        }
        if let candidate {
            metadata["profileID"] = candidate.profile.id.uuidString
            metadata["profileName"] = candidate.profile.name
            metadata["variantID"] = candidate.variantID?.uuidString ?? ""
            metadata["variantLabel"] = candidate.variantLabel ?? ""
            metadata["profileKind"] = candidate.profile.kind.rawValue
            metadata["recognizerKind"] = candidate.recognizerKind?.rawValue ?? ""
            metadata["recognitionScore"] = candidate.recognitionScore ?? NSNull()
            metadata["distance"] = candidate.distance
            metadata["threshold"] = candidate.profile.acceptanceThreshold
            metadata["scoreThreshold"] = candidate.profile.thresholds?.triggerScore ?? NSNull()
            metadata["confidence"] = candidate.confidence
            metadata["margin"] = candidate.margin ?? NSNull()
            metadata["marginThreshold"] = candidate.profile.marginThreshold
            metadata["secondBestDistance"] = candidate.secondBestDistance ?? NSNull()
            metadata["shouldTrigger"] = candidate.shouldTrigger
            metadata["soundFileName"] = candidate.profile.sound?.fileName ?? ""
            metadata["playedSoundFileName"] = triggered ? (lastTriggeredSound?.fileName ?? "") : ""
            metadata["triggerTiming"] = candidate.profile.triggerTiming.rawValue
            metadata["soundSequenceCount"] = candidate.profile.soundSequence?.count ?? 0
            metadata["soundVolume"] = candidate.profile.sound?.volume ?? 0
            metadata["candidate"] = [
                "profileID": candidate.profile.id.uuidString,
                "profileName": candidate.profile.name,
                "variantID": candidate.variantID?.uuidString ?? "",
                "variantLabel": candidate.variantLabel ?? "",
                "profileKind": candidate.profile.kind.rawValue,
                "recognizerKind": candidate.recognizerKind?.rawValue ?? "",
                "recognitionScore": candidate.recognitionScore ?? NSNull(),
                "rejectReason": candidate.rejectReason?.rawValue ?? "",
                "distance": candidate.distance,
                "threshold": candidate.profile.acceptanceThreshold,
                "scoreThreshold": candidate.profile.thresholds?.triggerScore ?? NSNull(),
                "confidence": candidate.confidence,
                "margin": candidate.margin ?? NSNull(),
                "marginThreshold": candidate.profile.marginThreshold,
                "secondBestDistance": candidate.secondBestDistance ?? NSNull(),
                "shouldTrigger": candidate.shouldTrigger,
                "soundFileName": candidate.profile.sound?.fileName ?? "",
                "playedSoundFileName": triggered ? (lastTriggeredSound?.fileName ?? "") : "",
                "triggerTiming": candidate.profile.triggerTiming.rawValue,
                "soundSequenceCount": candidate.profile.soundSequence?.count ?? 0,
                "soundVolume": candidate.profile.sound?.volume ?? 0,
            ]
        }
        return metadata
    }

    private func compactRecognitionEventMetadata(
        date: Date,
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        rejectionReason: BurstGateRejectionReason?,
        rejectReason: RejectReason?,
        tokens: [MotionToken],
        classifiedKind: MotionTokenKind?,
        candidateReports: [CandidateRecognitionReport],
        audioPlayed: Bool,
        audioReady: Bool,
        recognitionMs: Double,
        audioStartLatencyMs: Double?,
        triggered: Bool,
        csvFileName: String,
        jsonFileName: String
    ) -> [String: Any] {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var event: [String: Any] = [
            "schemaVersion": 2,
            "eventType": "watchRecognitionEvent",
            "testRunId": AppDiagnostics.currentRunID(),
            "buildCommit": AppDiagnostics.currentBuildCommit(),
            "deviceRole": "watchOS",
            "createdAt": timestampFormatter.string(from: date),
            "outcome": recognitionOutcome(triggered: triggered, candidate: candidate, rejectionReason: rejectionReason),
            "triggered": triggered,
            "audioPlayed": audioPlayed,
            "audioReady": audioReady,
            "audioStartLatencyMs": audioStartLatencyMs ?? -1,
            "recognitionMs": recognitionMs,
            "profileCount": recognitionRuntime.profiles.count,
            "profileLibraryReady": isProfileLibraryReady,
            "profileLibraryVersion": activeProfileLibraryVersion,
            "segmentKind": segment.kind.rawValue,
            "classifiedKind": classifiedKind?.rawValue ?? "",
            "sampleCount": segment.samples.count,
            "duration": segment.duration,
            "peakEnergy": segment.peakEnergy,
            "peakTimestamp": segment.peakTimestamp,
            "peakAcceleration": segment.features.peakAcceleration,
            "peakRotationRate": segment.features.peakRotationRate,
            "peakJerk": segment.features.peakJerk,
            "meanEnergy": segment.features.meanEnergy,
            "dominantAxis": segment.features.dominantAxis,
            "csvFileName": csvFileName,
            "jsonFileName": jsonFileName,
            "wearWrist": currentWearContext().wristLocation,
            "wearCrown": currentWearContext().crownOrientation,
        ]

        if let rejectionReason {
            event["rejectionReason"] = rejectionReason.rawValue
        }
        if let rejectReason {
            event["rejectReason"] = rejectReason.rawValue
        }
        if let candidate {
            event["profileID"] = candidate.profile.id.uuidString
            event["profileName"] = candidate.profile.name
            event["variantID"] = candidate.variantID?.uuidString ?? ""
            event["variantLabel"] = candidate.variantLabel ?? ""
            event["profileKind"] = candidate.profile.kind.rawValue
            event["recognizerKind"] = candidate.recognizerKind?.rawValue ?? ""
            event["recognitionScore"] = candidate.recognitionScore ?? -1
            event["distance"] = candidate.distance
            event["threshold"] = candidate.profile.acceptanceThreshold
            event["scoreThreshold"] = candidate.profile.thresholds?.triggerScore ?? -1
            event["confidence"] = candidate.confidence
            event["margin"] = candidate.margin ?? -1
            event["marginThreshold"] = candidate.profile.marginThreshold
            event["secondBestDistance"] = candidate.secondBestDistance ?? -1
            event["shouldTrigger"] = candidate.shouldTrigger
            event["soundFileName"] = candidate.profile.sound?.fileName ?? ""
            event["playedSoundFileName"] = triggered ? (lastTriggeredSound?.fileName ?? "") : ""
            event["triggerTiming"] = candidate.profile.triggerTiming.rawValue
        }

        event["tokens"] = tokens.prefix(6).map { token in
            [
                "kind": token.kind.rawValue,
                "duration": token.duration,
                "direction": token.direction,
                "magnitude": token.magnitude,
                "confidence": token.confidence,
                "peakAcc": token.peakAcc ?? -1,
                "peakGyro": token.peakGyro ?? -1,
                "integratedAngle": token.integratedAngle ?? -1,
                "oscillationCount": token.oscillationCount ?? -1,
            ] as [String: Any]
        }
        event["candidateReports"] = candidateReports.prefix(8).map { report in
            [
                "profileID": report.profileID.uuidString,
                "profileName": report.profileName,
                "variantID": report.variantID?.uuidString ?? "",
                "variantLabel": report.variantLabel ?? "",
                "recognizerKind": report.recognizerKind.rawValue,
                "score": report.score,
                "threshold": report.threshold,
                "margin": report.margin ?? -1,
                "shouldTrigger": report.shouldTrigger,
                "rejectReason": report.rejectReason?.rawValue ?? "",
            ] as [String: Any]
        }
        return event
    }

    private func sanitizeTraceFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return compact.isEmpty ? "gesture" : compact
    }

    private func pruneRecognitionTraceDirectory(_ directory: URL, keepingNewestFilePairs limit: Int) {
        do {
            let jsonFiles = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                modificationDate(lhs) > modificationDate(rhs)
            }

            for jsonURL in jsonFiles.dropFirst(limit) {
                let csvURL = jsonURL.deletingPathExtension().appendingPathExtension("csv")
                try? FileManager.default.removeItem(at: jsonURL)
                try? FileManager.default.removeItem(at: csvURL)
            }
        } catch {
            AppDiagnostics.record(error: error, event: "watch.recognition.tracePrune.error")
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }

    private func updateRecognitionSummary(
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        rejectionReason: BurstGateRejectionReason?
    ) {
        if recognitionRuntime.profiles.isEmpty {
            lastRecognitionSummary = "已检测到动作，但 Watch 没有已同步动作。"
            if segment.endTimestamp - lastNoProfileSummaryLogAt >= 10 {
                lastNoProfileSummaryLogAt = segment.endTimestamp
                AppDiagnostics.record(
                    "watch.recognition.noProfiles",
                    [
                        "segmentKind": segment.kind.rawValue,
                        "duration": segment.duration,
                        "peak": segment.features.peakAcceleration,
                    ]
                )
            }
            return
        }

        if let rejectionReason {
            lastRecognitionSummary = "动作被过滤：\(rejectionReason.rawValue)"
            AppDiagnostics.record(
                "watch.recognition.rejected",
                [
                    "reason": rejectionReason.rawValue,
                    "segmentKind": segment.kind.rawValue,
                    "duration": segment.duration,
                    "peak": segment.features.peakAcceleration,
                ]
            )
            return
        }

        guard let candidate else {
            lastRecognitionSummary = "检测到动作，但没有匹配到已保存动作。"
            AppDiagnostics.record(
                "watch.recognition.noCandidate",
                [
                    "segmentKind": segment.kind.rawValue,
                    "profileCount": recognitionRuntime.profiles.count,
                    "duration": segment.duration,
                    "peak": segment.features.peakAcceleration,
                ]
            )
            return
        }

        lastRecognitionSummary = candidate.shouldTrigger
            ? "已触发：\(candidate.profile.name)"
            : "检测到动作，但没有达到已保存动作的匹配要求。"
        AppDiagnostics.record(
            candidate.shouldTrigger ? "watch.recognition.candidateTriggered" : "watch.recognition.candidateRejected",
            [
                "profile": candidate.profile.name,
                "distance": candidate.distance,
                "threshold": candidate.profile.acceptanceThreshold,
                "margin": candidate.margin ?? -1,
                "marginThreshold": candidate.profile.marginThreshold,
                "confidence": candidate.confidence,
            ]
        )
    }
}

enum WatchMotionRecorderError: LocalizedError {
    case noSamples
    case recordingQualityRejected(message: String)
    case insufficientStandardTemplates(current: Int, required: Int)
    case standardDraftMismatch(expected: String)

    var errorDescription: String? {
        switch self {
        case .noSamples:
            return "没有可保存的录制样本"
        case let .recordingQualityRejected(message):
            return message
        case let .insufficientStandardTemplates(current, required):
            return "标准模式至少需要 \(required) 个样本，当前只有 \(current) 个"
        case let .standardDraftMismatch(expected):
            return "当前标准录制组是 \(expected)，请先重置再切换动作"
        }
    }
}

private struct RawMotionSample: Sendable {
    var timestamp: TimeInterval
    var userAcceleration: MotionVector3
    var rotationRate: MotionVector3
    var gravity: MotionVector3
    var attitude: MotionQuaternion

    init(_ motion: CMDeviceMotion) {
        timestamp = motion.timestamp
        userAcceleration = MotionVector3(
            x: motion.userAcceleration.x,
            y: motion.userAcceleration.y,
            z: motion.userAcceleration.z
        )
        rotationRate = MotionVector3(
            x: motion.rotationRate.x,
            y: motion.rotationRate.y,
            z: motion.rotationRate.z
        )
        gravity = MotionVector3(
            x: motion.gravity.x,
            y: motion.gravity.y,
            z: motion.gravity.z
        )
        attitude = MotionQuaternion(
            x: motion.attitude.quaternion.x,
            y: motion.attitude.quaternion.y,
            z: motion.attitude.quaternion.z,
            w: motion.attitude.quaternion.w
        )
    }

    func makeSample(start: TimeInterval?) -> MotionSample {
        MotionSample(
            timestamp: timestamp - (start ?? timestamp),
            userAcceleration: userAcceleration,
            rotationRate: rotationRate,
            gravity: gravity,
            attitude: attitude
        )
    }

    func makeSample(timestamp: TimeInterval) -> MotionSample {
        MotionSample(
            timestamp: timestamp,
            userAcceleration: userAcceleration,
            rotationRate: rotationRate,
            gravity: gravity,
            attitude: attitude
        )
    }
}

private struct MotionRuntimeRecognition: Sendable {
    var segment: GestureSegment
    var evaluation: RecognitionEvaluation
    var liveSample: MotionSample
    var source: String
    var recognitionMs: Double
}

private struct MotionRuntimeOutput: Sendable {
    var latestSample: MotionSample?
    var recordingSample: MotionSample?
    var recognition: MotionRuntimeRecognition?
    var motionCallbackCount: Int?

    var hasMainActorWork: Bool {
        latestSample != nil || recordingSample != nil || recognition != nil || motionCallbackCount != nil
    }
}

private actor MotionRuntimeActor {
    private var segmenter = MotionGestureSegmenter(
        configuration: GestureSegmenterConfiguration(
            postRollDuration: 0.05,
            endConfirmationDuration: 0.12,
            cooldownDuration: 0.22
        )
    )
    private var recognitionRuntime = GestureRecognitionRuntime(activeRecognitionSelection: .inactive)
    private var liveStartTimestamp: TimeInterval?
    private var recordingPreviousRawTimestamp: TimeInterval?
    private var recordingElapsedTimestamp: TimeInterval = 0
    private var nominalSampleInterval: TimeInterval = 0.02
    private var isRecording = false
    private var isProfileLibraryReady = false
    private var activeProfileLibraryVersion = ""
    private var expectedProfileCount = 0
    private var motionCallbackCount = 0
    private var firstMotionSampleLogged = false
    private var lastPublishedSampleAt: TimeInterval = -.infinity
    private var lastMotionHeartbeatAt: TimeInterval = 0
    private var lastSuppressedLogAt: TimeInterval = -.infinity
    private var recognitionSuppressedUntil: TimeInterval = 0
    private var rearmStatesByProfileID: [UUID: GestureRearmState] = [:]
    private var confirmationGate = GestureConfirmationGate()

    private struct GestureRearmState: Sendable {
        var isArmed: Bool
        var lastTriggerTimestamp: TimeInterval
        var quietSinceTimestamp: TimeInterval?
        var minimumCooldown: TimeInterval

        init(
            isArmed: Bool = true,
            lastTriggerTimestamp: TimeInterval = -.infinity,
            quietSinceTimestamp: TimeInterval? = nil,
            minimumCooldown: TimeInterval = 0.9
        ) {
            self.isArmed = isArmed
            self.lastTriggerTimestamp = lastTriggerTimestamp
            self.quietSinceTimestamp = quietSinceTimestamp
            self.minimumCooldown = minimumCooldown
        }
    }

    func configure(nominalSampleInterval: TimeInterval) {
        self.nominalSampleInterval = max(0.005, nominalSampleInterval)
    }

    func replaceProfiles(_ profiles: [GestureProfile]) {
        recognitionRuntime.replaceProfiles(profiles)
        rearmStatesByProfileID = rearmStatesByProfileID.filter { id, _ in
            profiles.contains { $0.id == id }
        }
        // 模板可能在同名/同 ID 下更新，重新按当前启用动作自适应分段阈值。
        adaptSegmenterToActiveProfiles(recognitionRuntime.activeProfileIDs)
        AppDiagnostics.record("watch.runtimeActor.profiles.replace", ["count": profiles.count])
    }

    func setActiveProfileIDs(_ profileIDs: Set<UUID>) {
        recognitionRuntime.setActiveProfileIDs(profileIDs)
        rearmStatesByProfileID = rearmStatesByProfileID.filter { id, _ in
            profileIDs.contains(id)
        }
        // 切换当前动作时清空待确认状态，避免旧动作的灰区证据带入新动作。
        confirmationGate.resetAll()
        adaptSegmenterToActiveProfiles(profileIDs)
        AppDiagnostics.record(
            "watch.runtimeActor.activeProfiles.set",
            [
                "count": profileIDs.count,
                "profileIDs": profileIDs.map(\.uuidString).sorted().joined(separator: ","),
                "segmenterStartEnergy": segmenter.configuration.startEnergyThreshold,
            ]
        )
    }

    /// B4：按当前启用动作自适应分段能量阈值。
    /// 只在"恰好一个动作启用"时调整，且只会把起始阈值"抬高"到默认值之上——
    /// 对强动作（如出拳）提高门槛，让微弱的日常手腕移动根本不会成段；
    /// 对柔和动作则保持安全的默认值，不会降低门槛而引入更多误段。
    private func adaptSegmenterToActiveProfiles(_ profileIDs: Set<UUID>) {
        let defaults = GestureSegmenterConfiguration(
            postRollDuration: 0.05,
            endConfirmationDuration: 0.12,
            cooldownDuration: 0.22
        )
        guard profileIDs.count == 1,
              let id = profileIDs.first,
              let profile = recognitionRuntime.profiles.first(where: { $0.id == id }) else {
            segmenter.configuration = defaults
            return
        }

        // 模板的代表性能量（与分段能量同口径：acc + 0.25*gyro）。
        let energies: [Double] = profile.templates.compactMap { template in
            guard let f = template.features else { return nil }
            return f.peakAcceleration + 0.25 * f.peakRotationRate
        }
        guard let peakEnergy = energies.max(), peakEnergy > 0 else {
            segmenter.configuration = defaults
            return
        }

        var config = defaults
        // 只抬高，不降低；上限避免把阈值设得过高而漏掉真实动作。
        let adaptedStart = min(1.2, max(defaults.startEnergyThreshold, peakEnergy * 0.30))
        config.startEnergyThreshold = adaptedStart
        config.endEnergyThreshold = min(defaults.endEnergyThreshold * 2.0, adaptedStart * 0.42)
        segmenter.configuration = config
        AppDiagnostics.record(
            "watch.runtimeActor.segmenterAdapted",
            [
                "profile": profile.name,
                "peakEnergy": peakEnergy,
                "startEnergy": adaptedStart,
                "endEnergy": config.endEnergyThreshold,
            ]
        )
    }

    func updateProfileLibraryState(isReady: Bool, version: String, expectedProfileCount: Int) {
        isProfileLibraryReady = isReady
        activeProfileLibraryVersion = version
        self.expectedProfileCount = expectedProfileCount
        if !isReady {
            resetRuntimeState()
        }
    }

    func resetRuntimeState() {
        segmenter.reset()
        recognitionRuntime.resetRuntimeState()
        rearmStatesByProfileID.removeAll()
        confirmationGate.resetAll()
        lastSuppressedLogAt = -.infinity
    }

    func startRecording() {
        isRecording = true
        recordingPreviousRawTimestamp = nil
        recordingElapsedTimestamp = 0
        segmenter.reset()
        recognitionSuppressedUntil = (currentLiveTimestamp ?? 0) + 30
        AppDiagnostics.record("watch.runtimeActor.recording.start", ["recognitionSuppressedUntil": recognitionSuppressedUntil])
    }

    func stopRecording() {
        isRecording = false
        recordingPreviousRawTimestamp = nil
        recordingElapsedTimestamp = 0
        segmenter.reset()
        recognitionSuppressedUntil = (currentLiveTimestamp ?? 0) + 1.25
        AppDiagnostics.record("watch.runtimeActor.recording.stop", ["recognitionSuppressedUntil": recognitionSuppressedUntil])
    }

    func stop() {
        isRecording = false
        liveStartTimestamp = nil
        recordingPreviousRawTimestamp = nil
        recordingElapsedTimestamp = 0
        firstMotionSampleLogged = false
        lastPublishedSampleAt = -.infinity
        lastMotionHeartbeatAt = 0
        lastSuppressedLogAt = -.infinity
        recognitionSuppressedUntil = 0
        resetRuntimeState()
    }

    func ingest(_ rawSample: RawMotionSample) -> MotionRuntimeOutput {
        motionCallbackCount += 1
        if liveStartTimestamp == nil {
            liveStartTimestamp = rawSample.timestamp
        }
        let liveSample = rawSample.makeSample(start: liveStartTimestamp)
        let latestSample = publishLatestSampleIfNeeded(liveSample)
        var output = MotionRuntimeOutput(
            latestSample: latestSample,
            recordingSample: nil,
            recognition: nil,
            motionCallbackCount: latestSample == nil ? nil : motionCallbackCount
        )

        recordFirstMotionSampleIfNeeded(rawSample: rawSample, sample: liveSample)
        recordMotionHeartbeatIfNeeded(sample: liveSample)
        updateRearmStates(sample: liveSample)

        if isRecording {
            output.recordingSample = normalizedRecordingSample(from: rawSample)
            output.motionCallbackCount = motionCallbackCount
            return output
        }

        guard liveSample.timestamp >= recognitionSuppressedUntil else {
            return output
        }

        guard isProfileLibraryReady else {
            recordRecognitionSuppressedIfNeeded(sample: liveSample, reason: "profileLibraryNotReady")
            return output
        }

        guard !recognitionRuntime.profiles.isEmpty else {
            recordRecognitionSuppressedIfNeeded(sample: liveSample, reason: "noProfiles")
            return output
        }

        guard !recognitionRuntime.activeProfiles.isEmpty else {
            recordRecognitionSuppressedIfNeeded(sample: liveSample, reason: "noActiveProfile")
            return output
        }

        if let recognition = evaluateContinuous(sample: liveSample) {
            output.recognition = recognition
            output.motionCallbackCount = motionCallbackCount
            if recognition.evaluation.candidate?.shouldTrigger == true {
                return output
            }
        }

        if let segment = segmenter.ingest(liveSample) {
            output.recognition = evaluate(segment: segment, liveSample: liveSample, source: "segment")
            output.motionCallbackCount = motionCallbackCount
        }
        return output
    }

    private var currentLiveTimestamp: TimeInterval? {
        guard let liveStartTimestamp else { return nil }
        return ProcessInfo.processInfo.systemUptime - liveStartTimestamp
    }

    private func publishLatestSampleIfNeeded(_ sample: MotionSample) -> MotionSample? {
        guard sample.timestamp - lastPublishedSampleAt >= 0.20 else { return nil }
        lastPublishedSampleAt = sample.timestamp
        return sample
    }

    private func evaluateContinuous(sample liveSample: MotionSample) -> MotionRuntimeRecognition? {
        let start = ProcessInfo.processInfo.systemUptime
        guard let continuous = recognitionRuntime.evaluateContinuous(sample: liveSample, now: liveSample.timestamp) else {
            return nil
        }
        let recognitionMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let evaluation = applyRearmPolicy(
            to: continuous.evaluation,
            at: liveSample.timestamp,
            source: "continuous"
        )
        return MotionRuntimeRecognition(
            segment: continuous.segment,
            evaluation: evaluation,
            liveSample: liveSample,
            source: "continuous",
            recognitionMs: recognitionMs
        )
    }

    private func evaluate(segment: GestureSegment, liveSample: MotionSample, source: String) -> MotionRuntimeRecognition {
        let start = ProcessInfo.processInfo.systemUptime
        let rawEvaluation = recognitionRuntime.evaluate(segment: segment, now: liveSample.timestamp)
        let recognitionMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let evaluation = applyRearmPolicy(to: rawEvaluation, at: liveSample.timestamp, source: source)
        return MotionRuntimeRecognition(
            segment: segment,
            evaluation: evaluation,
            liveSample: liveSample,
            source: source,
            recognitionMs: recognitionMs
        )
    }

    private func applyRearmPolicy(
        to evaluation: RecognitionEvaluation,
        at timestamp: TimeInterval,
        source: String
    ) -> RecognitionEvaluation {
        var evaluation = evaluation
        guard var candidate = evaluation.candidate,
              candidate.shouldTrigger else {
            return evaluation
        }

        if !isArmedForTrigger(profile: candidate.profile) {
            candidate.rejectReason = .cooldownActive
            evaluation.candidate = candidate
            evaluation.rejectReason = .cooldownActive
            AppDiagnostics.record(
                "watch.recognition.rearmBlocked",
                [
                    "profile": candidate.profile.name,
                    "timestamp": timestamp,
                    "source": source,
                ]
            )
            return evaluation
        }

        // 二次确认（灰区）：分数刚过线的候选需相邻窗口再次命中才触发。
        // 高置信候选 confirmationGate 直接放行，不增加延迟。
        let score = candidate.recognitionScore ?? candidate.confidence
        let threshold = candidate.profile.thresholds?.triggerScore ?? candidate.profile.acceptanceThreshold
        if confirmationGate.register(
            profileID: candidate.profile.id,
            score: score,
            threshold: threshold,
            at: timestamp
        ) == .wait {
            candidate.rejectReason = .awaitingConfirmation
            evaluation.candidate = candidate
            evaluation.rejectReason = .awaitingConfirmation
            AppDiagnostics.record(
                "watch.recognition.awaitingConfirmation",
                [
                    "profile": candidate.profile.name,
                    "score": score,
                    "threshold": threshold,
                    "source": source,
                ]
            )
            return evaluation
        }

        markTriggered(profile: candidate.profile, at: timestamp)
        recognitionRuntime.markTriggered(profileID: candidate.profile.id, at: timestamp)
        return evaluation
    }

    private func isArmedForTrigger(profile: GestureProfile) -> Bool {
        rearmStatesByProfileID[profile.id, default: GestureRearmState()].isArmed
    }

    private func markTriggered(profile: GestureProfile, at timestamp: TimeInterval) {
        let cooldown = max(0.9, profile.cooldownSeconds)
        rearmStatesByProfileID[profile.id] = GestureRearmState(
            isArmed: false,
            lastTriggerTimestamp: timestamp,
            quietSinceTimestamp: nil,
            minimumCooldown: cooldown
        )
    }

    private func updateRearmStates(sample: MotionSample) {
        guard !rearmStatesByProfileID.isEmpty else { return }
        let energy = sample.userAcceleration.magnitude + 0.25 * sample.rotationRate.magnitude
        let quietThreshold = 0.34
        let quietDuration = 0.34
        let maxLockedDuration = 3.5

        for profileID in rearmStatesByProfileID.keys {
            guard var state = rearmStatesByProfileID[profileID], !state.isArmed else {
                continue
            }

            let elapsed = sample.timestamp - state.lastTriggerTimestamp
            if elapsed >= maxLockedDuration {
                state.isArmed = true
                state.quietSinceTimestamp = nil
                rearmStatesByProfileID[profileID] = state
                AppDiagnostics.record("watch.recognition.rearmed", ["profileID": profileID.uuidString, "reason": "timeout"])
                continue
            }

            guard elapsed >= state.minimumCooldown else {
                state.quietSinceTimestamp = nil
                rearmStatesByProfileID[profileID] = state
                continue
            }

            if energy <= quietThreshold {
                if state.quietSinceTimestamp == nil {
                    state.quietSinceTimestamp = sample.timestamp
                }
                if let quietSince = state.quietSinceTimestamp,
                   sample.timestamp - quietSince >= quietDuration {
                    state.isArmed = true
                    state.quietSinceTimestamp = nil
                    AppDiagnostics.record(
                        "watch.recognition.rearmed",
                        [
                            "profileID": profileID.uuidString,
                            "reason": "quiet",
                            "quietDuration": sample.timestamp - quietSince,
                        ]
                    )
                }
            } else {
                state.quietSinceTimestamp = nil
            }
            rearmStatesByProfileID[profileID] = state
        }
    }

    private func normalizedRecordingSample(from rawSample: RawMotionSample) -> MotionSample {
        if let previous = recordingPreviousRawTimestamp {
            let rawDelta = rawSample.timestamp - previous
            if rawDelta > 0, rawDelta <= 0.20 {
                recordingElapsedTimestamp += rawDelta
            } else {
                recordingElapsedTimestamp += nominalSampleInterval
                if rawDelta > 0.50 {
                    AppDiagnostics.record(
                        "watch.recording.timestampGap.clamped",
                        [
                            "rawDelta": rawDelta,
                            "nominalDelta": nominalSampleInterval,
                        ]
                    )
                }
            }
        } else {
            recordingElapsedTimestamp = 0
        }
        recordingPreviousRawTimestamp = rawSample.timestamp
        return rawSample.makeSample(timestamp: recordingElapsedTimestamp)
    }

    private func recordFirstMotionSampleIfNeeded(rawSample: RawMotionSample, sample: MotionSample) {
        guard !firstMotionSampleLogged else { return }
        firstMotionSampleLogged = true
        AppDiagnostics.record(
            "watch.motion.firstSample",
            [
                "rawTimestamp": rawSample.timestamp,
                "liveTimestamp": sample.timestamp,
                "acceleration": sample.userAcceleration.magnitude,
                "rotation": sample.rotationRate.magnitude,
                "runtime": "actor",
            ]
        )
    }

    private func recordMotionHeartbeatIfNeeded(sample: MotionSample) {
        let now = sample.timestamp
        guard now - lastMotionHeartbeatAt >= 2 else { return }
        lastMotionHeartbeatAt = now
        AppDiagnostics.record(
            "watch.motion.heartbeat",
            [
                "timestamp": sample.timestamp,
                "acceleration": sample.userAcceleration.magnitude,
                "rotation": sample.rotationRate.magnitude,
                "isRecording": isRecording,
                "profileCount": recognitionRuntime.profiles.count,
                "expectedProfileCount": expectedProfileCount,
                "runtime": "actor",
            ]
        )
    }

    private func recordRecognitionSuppressedIfNeeded(sample: MotionSample, reason: String) {
        guard sample.timestamp - lastSuppressedLogAt >= 5 else {
            return
        }
        lastSuppressedLogAt = sample.timestamp
        AppDiagnostics.record(
            "watch.recognition.suppressed",
            [
                "reason": reason,
                "profileLibraryReady": isProfileLibraryReady,
                "profileLibraryVersion": activeProfileLibraryVersion,
                "loadedProfileCount": recognitionRuntime.profiles.count,
                "activeProfileCount": recognitionRuntime.activeProfiles.count,
                "runtime": "actor",
            ]
        )
    }
}

private extension JSONEncoder {
    static var motionSound: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// Watch 端动作选择 UI 使用的轻量摘要。
struct WatchGestureProfileSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let kind: GestureKind
}

/// 激活选择的本地持久化（UserDefaults），用于跨 App 重启恢复。
enum WatchActiveProfileSelectionStore {
    private static let key = "MotionSound.activeProfileSelection.v1"

    static func load(defaults: UserDefaults = .standard) -> ActiveProfileSyncState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? MotionSoundSyncCodec.decode(ActiveProfileSyncState.self, from: data)
    }

    static func save(_ state: ActiveProfileSyncState?, defaults: UserDefaults = .standard) {
        guard let state, let data = try? MotionSoundSyncCodec.encode(state) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
