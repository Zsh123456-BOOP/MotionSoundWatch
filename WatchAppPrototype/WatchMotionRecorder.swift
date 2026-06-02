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
    @Published private(set) var lastBurstGateRejectionReason: BurstGateRejectionReason?
    @Published private(set) var lastFeedbackMessage: String?
    @Published private(set) var standardTemplateCount = 0
    @Published private(set) var standardNegativeTemplateCount = 0
    @Published private(set) var standardRequiredTemplateCount = 3
    @Published private(set) var standardQuality: GestureQuality?

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let validator = MotionRecordingValidator()
    private let templateBuilder = MotionTemplateBuilder()
    private let profileBuilder = GestureProfileBuilder()
    private let feedbackEngine = GestureFeedbackEngine()
    private let soundPlayer: WatchSoundPlayer?
    private var segmenter = MotionGestureSegmenter()
    private var recognitionRuntime = GestureRecognitionRuntime()
    private var recordingStartTimestamp: TimeInterval?
    private var standardTemplates: [MotionTemplate] = []
    private var standardNegativeTemplates: [MotionTemplate] = []
    private var standardLabel: String?
    private var standardKind: GestureKind?

    init(soundPlayer: WatchSoundPlayer? = nil) {
        self.soundPlayer = soundPlayer
        motionQueue.name = "watch.motion.sound.core-motion"
        motionQueue.qualityOfService = .userInitiated
        AppDiagnostics.record("watch.motionRecorder.init")
    }

    func startLiveUpdates(sampleRate: Double = 50) {
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
        AppDiagnostics.record("watch.motion.startLiveUpdates", ["sampleRate": sampleRate])
    }

    func stopLiveUpdates() {
        motionManager.stopDeviceMotionUpdates()
        isLive = false
        isRecording = false
        AppDiagnostics.record("watch.motion.stopLiveUpdates")
    }

    func startRecording() {
        samples.removeAll(keepingCapacity: true)
        lastAssessment = nil
        recordingStartTimestamp = nil
        estimatedSampleRate = 0
        lastSegment = nil
        savedProfileURL = nil
        savedRecordingURL = nil
        segmenter.reset()
        isRecording = true
        if !isLive {
            startLiveUpdates()
        }
        AppDiagnostics.record("watch.recording.start")
    }

    func reloadSavedProfiles() {
        do {
            let store = try GestureProfileFileStore.appDocumentsStore()
            let profiles = try store.list().flatMap(\.archive.profiles)
            recognitionRuntime.replaceProfiles(profiles)
            soundPlayer?.preload(sounds: profiles.map(\.sound))
            loadedProfileCount = profiles.count
            lastFeedbackMessage = nil
            AppDiagnostics.record("watch.profiles.reload", ["count": profiles.count])
        } catch {
            loadedProfileCount = 0
            lastFeedbackMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.profiles.reload.error")
        }
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
            lastFeedbackMessage = "已加入负样本并更新阈值"
            AppDiagnostics.record("watch.feedback.falseTriggerApplied", ["profileCount": updatedProfiles.count])
        } catch {
            lastFeedbackMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.feedback.falseTrigger.error")
        }
    }

    func stopRecording() -> [MotionSample] {
        isRecording = false
        lastAssessment = validator.assess(samples)
        AppDiagnostics.record(
            "watch.recording.stop",
            [
                "samples": samples.count,
                "duration": lastAssessment?.duration ?? 0,
                "sampleRate": lastAssessment?.estimatedSampleRate ?? 0,
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
        lastFeedbackMessage = "已加入标准样本 \(standardTemplateCount)/\(standardRequiredTemplateCount)"
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
        lastFeedbackMessage = "已加入负样本 \(standardNegativeTemplateCount)"
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
        if isRecording, recordingStartTimestamp == nil {
            recordingStartTimestamp = rawSample.timestamp
        }

        let sample = rawSample.makeSample(start: recordingStartTimestamp)
        latestSample = sample
        if let segment = segmenter.ingest(sample) {
            lastSegment = segment
            AppDiagnostics.record(
                "watch.motion.segment",
                [
                    "kind": segment.kind.rawValue,
                    "duration": segment.duration,
                    "peakEnergy": segment.peakEnergy,
                ]
            )
            let evaluation = recognitionRuntime.evaluate(segment: segment, now: sample.timestamp)
            let candidate = evaluation.candidate
            lastBurstGateRejectionReason = evaluation.burstGateRejectionReason
            let audioPlayed = candidate?.shouldTrigger == true
                ? (soundPlayer?.play(sound: candidate?.profile.sound) ?? false)
                : false
            lastRecognitionEvent = recognitionRuntime.record(
                segment: segment,
                candidate: candidate,
                now: sample.timestamp,
                wearContext: currentWearContext(),
                audioPlayed: audioPlayed,
                burstGateRejectionReason: evaluation.burstGateRejectionReason
            )
            if lastRecognitionEvent?.triggered == true {
                AppDiagnostics.record(
                    "watch.recognition.triggered",
                    [
                        "profile": lastRecognitionEvent?.profile?.name ?? "",
                        "audioPlayed": audioPlayed,
                    ]
                )
                WKInterfaceDevice.current().play(.success)
            }
        }

        guard isRecording else { return }
        samples.append(sample)
        lastAssessment = validator.assess(samples)
        estimatedSampleRate = lastAssessment?.estimatedSampleRate ?? 0
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
}

private extension JSONEncoder {
    static var motionSound: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
