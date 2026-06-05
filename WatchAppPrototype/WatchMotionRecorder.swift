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
    @Published private(set) var lastSegment: GestureSegment?
    @Published private(set) var savedProfileURL: URL?
    @Published private(set) var savedRecordingURL: URL?
    @Published private(set) var loadedProfileCount = 0
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
    @Published private(set) var standardRequiredTemplateCount = 3
    @Published private(set) var standardQuality: GestureQuality?
    var recognitionEventSink: (([String: Any]) -> Void)?

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let validator = MotionRecordingValidator()
    private let templateBuilder = MotionTemplateBuilder()
    private let profileBuilder = GestureProfileBuilder()
    private let feedbackEngine = GestureFeedbackEngine()
    private let soundPlayer: WatchSoundPlayer?
    private var segmenter = MotionGestureSegmenter(
        configuration: GestureSegmenterConfiguration(
            postRollDuration: 0.05,
            endConfirmationDuration: 0.12,
            cooldownDuration: 0.22
        )
    )
    private var recognitionRuntime = GestureRecognitionRuntime()
    private var recordingStartTimestamp: TimeInterval?
    private var recordingPreviousRawTimestamp: TimeInterval?
    private var recordingElapsedTimestamp: TimeInterval = 0
    private var liveStartTimestamp: TimeInterval?
    private var standardTemplates: [MotionTemplate] = []
    private var standardNegativeTemplates: [MotionTemplate] = []
    private var standardLabel: String?
    private var standardKind: GestureKind?
    private var triggerCountsByProfileID: [UUID: Int] = [:]
    private var lastMotionHeartbeatAt: TimeInterval = 0
    private var lastNoProfileSummaryLogAt: TimeInterval = -.infinity
    private var lastNonCandidateTraceAt: TimeInterval = -.infinity
    private var recognitionSuppressedUntil: TimeInterval = 0
    private var motionCallbackCount = 0
    private var firstMotionSampleLogged = false
    private var motionStartDiagnosticTask: Task<Void, Never>?

    init(soundPlayer: WatchSoundPlayer? = nil) {
        self.soundPlayer = soundPlayer
        motionQueue.name = "watch.motion.sound.core-motion"
        motionQueue.qualityOfService = .userInitiated
        AppDiagnostics.record("watch.motionRecorder.init")
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
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            if let error {
                AppDiagnostics.record(error: error, event: "watch.motion.callback.error")
                return
            }
            guard let self else { return }
            guard let motion else {
                AppDiagnostics.record("watch.motion.callback.empty")
                return
            }
            let rawSample = RawMotionSample(motion)
            self.receive(rawSample)
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
        liveStartTimestamp = nil
        recordingStartTimestamp = nil
        recordingPreviousRawTimestamp = nil
        recordingElapsedTimestamp = 0
        firstMotionSampleLogged = false
        recognitionSuppressedUntil = 0
        AppDiagnostics.record("watch.motion.stopLiveUpdates")
    }

    func startRecording() {
        samples.removeAll(keepingCapacity: true)
        lastAssessment = nil
        recordingStartTimestamp = nil
        recordingPreviousRawTimestamp = nil
        recordingElapsedTimestamp = 0
        estimatedSampleRate = 0
        lastSegment = nil
        savedProfileURL = nil
        savedRecordingURL = nil
        segmenter.reset()
        recognitionSuppressedUntil = (latestSample?.timestamp ?? 0) + 30
        lastRecognitionSummary = "录制中，已暂停动作触发。"
        isRecording = true
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
            triggerCountsByProfileID = triggerCountsByProfileID.filter { id, _ in
                profiles.contains { $0.id == id }
            }
            soundPlayer?.preload(profileSounds: profiles)
            loadedProfileCount = profiles.count
            lastFeedbackMessage = nil
            AppDiagnostics.record("watch.profiles.reload", ["count": profiles.count])
        } catch {
            loadedProfileCount = 0
            lastFeedbackMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.profiles.reload.error")
        }
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
            let archive = GestureProfileArchive(profiles: updatedProfiles)
            let store = try GestureProfileFileStore.appDocumentsStore()
            _ = try store.save(archive, preferredName: "feedback-updated-profiles")
            recognitionRuntime.replaceProfiles(updatedProfiles)
            loadedProfileCount = updatedProfiles.count
            lastFeedbackMessage = "已记录误触反馈并更新阈值"
            AppDiagnostics.record("watch.feedback.falseTriggerApplied", ["profileCount": updatedProfiles.count])
        } catch {
            lastFeedbackMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.feedback.falseTrigger.error")
        }
    }

    func stopRecording() -> [MotionSample] {
        isRecording = false
        lastAssessment = validator.assess(samples)
        segmenter.reset()
        if let latestSample {
            recognitionSuppressedUntil = latestSample.timestamp + 1.25
        }
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
    }

    @discardableResult
    func addCurrentRecordingToStandardProfile(label: String, kind: GestureKind) throws -> Int {
        guard !samples.isEmpty else {
            throw WatchMotionRecorderError.noSamples
        }

        let trimmedLabel = normalizedLabel(label)
        try setStandardDraftIdentity(label: trimmedLabel, kind: kind)

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

    private func receive(_ rawSample: RawMotionSample) {
        motionCallbackCount += 1
        if liveStartTimestamp == nil {
            liveStartTimestamp = rawSample.timestamp
        }
        if isRecording, recordingStartTimestamp == nil {
            recordingStartTimestamp = rawSample.timestamp
        }

        let liveSample = rawSample.makeSample(start: liveStartTimestamp)
        latestSample = liveSample
        recordFirstMotionSampleIfNeeded(rawSample: rawSample, sample: liveSample)
        recordMotionHeartbeatIfNeeded(sample: liveSample)

        if isRecording {
            let recordingSample = normalizedRecordingSample(from: rawSample)
            samples.append(recordingSample)
            lastAssessment = validator.assess(samples)
            estimatedSampleRate = lastAssessment?.estimatedSampleRate ?? 0
            return
        }

        guard liveSample.timestamp >= recognitionSuppressedUntil else {
            return
        }

        if let segment = segmenter.ingest(liveSample) {
            lastSegment = segment
            AppDiagnostics.record(
                "watch.motion.segment",
                [
                    "kind": segment.kind.rawValue,
                    "duration": segment.duration,
                    "peakEnergy": segment.peakEnergy,
                ]
            )
            let evaluation = recognitionRuntime.evaluate(segment: segment, now: liveSample.timestamp)
            let candidate = evaluation.candidate
            lastBurstGateRejectionReason = evaluation.burstGateRejectionReason
            updateRecognitionSummary(segment: segment, candidate: candidate, rejectionReason: evaluation.burstGateRejectionReason)
            let soundToPlay = candidate?.shouldTrigger == true ? nextSound(for: candidate?.profile) : nil
            let audioPlayRequested = candidate?.shouldTrigger == true
                ? (soundPlayer?.play(sound: soundToPlay) ?? false)
                : false
            let audioPlayed = audioPlayRequested && (soundPlayer?.lastAudiblePlaySucceeded ?? audioPlayRequested)
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
                rejectReason: evaluation.rejectReason
            )
            if lastRecognitionEvent?.triggered == true {
                if let profileID = lastRecognitionEvent?.profile?.id {
                    triggerCountsByProfileID[profileID, default: 0] += 1
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
                        "profile": lastRecognitionEvent?.profile?.name ?? "",
                        "audioPlayed": audioPlayed,
                        "audioPlayRequested": audioPlayRequested,
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
                rejectReason: evaluation.rejectReason,
                tokens: evaluation.tokens,
                classifiedKind: evaluation.classifiedKind,
                candidateReports: evaluation.candidateReports,
                audioPlayed: audioPlayed,
                triggered: lastRecognitionEvent?.triggered == true
            )
        }
    }

    private func normalizedRecordingSample(from rawSample: RawMotionSample) -> MotionSample {
        let nominalInterval = motionManager.deviceMotionUpdateInterval > 0
            ? motionManager.deviceMotionUpdateInterval
            : 0.02
        if let previous = recordingPreviousRawTimestamp {
            let rawDelta = rawSample.timestamp - previous
            if rawDelta > 0, rawDelta <= 0.20 {
                recordingElapsedTimestamp += rawDelta
            } else {
                recordingElapsedTimestamp += nominalInterval
                if rawDelta > 0.50 {
                    AppDiagnostics.record(
                        "watch.recording.timestampGap.clamped",
                        [
                            "rawDelta": rawDelta,
                            "nominalDelta": nominalInterval,
                            "sampleCount": samples.count,
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
            ]
        )
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

            try MotionSampleCSVCodec().encodeData(segment.samples).write(to: csvURL, options: [.atomic])
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
                triggered: triggered,
                csvFileName: csvURL.lastPathComponent
            )
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: jsonURL, options: [.atomic])
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
        triggered: Bool,
        csvFileName: String
    ) -> [String: Any] {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var metadata: [String: Any] = [
            "schemaVersion": 1,
            "createdAt": timestampFormatter.string(from: date),
            "csvFileName": csvFileName,
            "outcome": recognitionOutcome(triggered: triggered, candidate: candidate, rejectionReason: rejectionReason),
            "triggered": triggered,
            "audioPlayed": audioPlayed,
            "profileCount": recognitionRuntime.profiles.count,
            "segmentKind": segment.kind.rawValue,
            "classifiedKind": classifiedKind?.rawValue ?? "",
            "sampleCount": segment.samples.count,
            "duration": segment.duration,
            "startTimestamp": segment.startTimestamp,
            "endTimestamp": segment.endTimestamp,
            "peakEnergy": segment.peakEnergy,
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
        triggered: Bool,
        csvFileName: String,
        jsonFileName: String
    ) -> [String: Any] {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var event: [String: Any] = [
            "schemaVersion": 1,
            "eventType": "watchRecognitionEvent",
            "testRunId": AppDiagnostics.currentRunID(),
            "buildCommit": AppDiagnostics.currentBuildCommit(),
            "deviceRole": "watchOS",
            "createdAt": timestampFormatter.string(from: date),
            "outcome": recognitionOutcome(triggered: triggered, candidate: candidate, rejectionReason: rejectionReason),
            "triggered": triggered,
            "audioPlayed": audioPlayed,
            "profileCount": recognitionRuntime.profiles.count,
            "segmentKind": segment.kind.rawValue,
            "classifiedKind": classifiedKind?.rawValue ?? "",
            "sampleCount": segment.samples.count,
            "duration": segment.duration,
            "peakEnergy": segment.peakEnergy,
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

    private func recordMotionHeartbeatIfNeeded(sample: MotionSample) {
        guard isLive else { return }
        let now = sample.timestamp
        guard now - lastMotionHeartbeatAt >= 2 else { return }
        lastMotionHeartbeatAt = now

        let accelerationMagnitude = sqrt(
            sample.userAcceleration.x * sample.userAcceleration.x
                + sample.userAcceleration.y * sample.userAcceleration.y
                + sample.userAcceleration.z * sample.userAcceleration.z
        )
        let rotationMagnitude = sqrt(
            sample.rotationRate.x * sample.rotationRate.x
                + sample.rotationRate.y * sample.rotationRate.y
                + sample.rotationRate.z * sample.rotationRate.z
        )
        AppDiagnostics.record(
            "watch.motion.heartbeat",
            [
                "timestamp": sample.timestamp,
                "acceleration": accelerationMagnitude,
                "rotation": rotationMagnitude,
                "isRecording": isRecording,
                "profileCount": recognitionRuntime.profiles.count,
                "loadedProfileCount": loadedProfileCount,
            ]
        )
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
            : String(
                format: "%@ 未触发，距离 %.3f / 阈值 %.3f",
                candidate.profile.name,
                candidate.distance,
                candidate.profile.acceptanceThreshold
            )
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
    case insufficientStandardTemplates(current: Int, required: Int)
    case standardDraftMismatch(expected: String)

    var errorDescription: String? {
        switch self {
        case .noSamples:
            return "没有可保存的录制样本"
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

private extension JSONEncoder {
    static var motionSound: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
