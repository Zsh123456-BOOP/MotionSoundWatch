import Testing
import Foundation
@testable import MotionSoundCore

@Test func validatorTreatsDurationAsWarningNotHardFailure() {
    let shortPunch = syntheticBurst(duration: 0.18, amplitude: 1.2)
    let longSequence = syntheticSequence(duration: 5.2, amplitude: 0.9)
    let validator = MotionRecordingValidator()

    let shortAssessment = validator.assess(shortPunch)
    let longAssessment = validator.assess(longSequence)

    #expect(shortAssessment.canSave)
    #expect(longAssessment.canSave)
    #expect(shortAssessment.warnings.contains { $0.contains("短促动作") })
    #expect(longAssessment.warnings.contains { $0.contains("长动作") })
}

@Test func recordingQualityRejectsClearlyBadSamples() {
    let validator = MotionRecordingValidator()
    let lowAmplitude = syntheticBurst(duration: 0.7, amplitude: 0.03)

    let report = validator.qualityReport(samples: lowAmplitude, draftKind: .burst)

    #expect(report.canUseForTraining == false)
    #expect(report.shouldAskRerecord)
    #expect(report.energyScore < 0.18)
    #expect(report.warnings.contains { $0.contains("动作幅度太低") })
}

@Test func recordingQualityFlagsSamplesThatDriftFromExistingPositives() {
    let builder = MotionTemplateBuilder()
    let positives = [
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.04, phase: 0.02)),
    ]

    let report = MotionRecordingValidator().qualityReport(
        samples: syntheticRotation(duration: 1.4, angle: .pi * 2),
        draftKind: .burst,
        existingPositiveTemplates: positives
    )

    #expect(report.canUseForTraining == false)
    #expect(report.shouldAskRerecord)
    #expect(report.similarityToExistingSamples != nil)
    #expect(report.warnings.contains { $0.contains("不一致") })
}

@Test func matcherScoresSimilarGestureCloserThanDifferentGesture() {
    let matcher = MotionTemplateMatcher()
    let template = syntheticBurst(duration: 0.8, amplitude: 1.0)
    let similar = syntheticBurst(duration: 0.92, amplitude: 1.05, phase: 0.05)
    let different = syntheticSequence(duration: 0.8, amplitude: 1.0)

    let similarDistance = matcher.distance(template, similar)
    let differentDistance = matcher.distance(template, different)

    #expect(similarDistance < differentDistance)
}

@Test func tokenizerCalibrationAllowsLightUserImpulse() {
    let features = MotionFeatureExtractor().extract(syntheticBurst(duration: 0.7, amplitude: 0.38))
    let calibration = TokenizerCalibration(
        impulsePeakAccP20: 0.35,
        impulsePeakGyroP20: 0.12
    )

    #expect(MotionTokenizer().classify(features, calibration: calibration) == .impulse)
}

@Test func dominantAxisEstimateSupportsDiagonalRotation() {
    let samples = syntheticDiagonalRotation(duration: 1.2, angle: .pi * 2)
    let estimate = MotionFeatureExtractor().dominantAxisEstimate(samples)

    #expect(estimate.absoluteAngle > .pi * 1.8)
    #expect(estimate.stability > 0.92)
    #expect(abs(estimate.axis.x) > 0.45)
    #expect(abs(estimate.axis.z) > 0.45)
}

@Test func calibrationUsesPositiveAndNegativeSamples() {
    let matcher = MotionTemplateMatcher()
    let templates = [
        MotionTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0), qualityScore: 0.9),
        MotionTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.74, amplitude: 1.03, phase: 0.03), qualityScore: 0.9),
        MotionTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.04), qualityScore: 0.9),
    ]
    let negative = [syntheticSequence(duration: 0.7, amplitude: 1.0)]

    let calibration = matcher.calibrateThreshold(positiveTemplates: templates, negativeWindows: negative)
    let profile = GestureProfile(
        name: "punch",
        kind: .burst,
        templates: templates,
        acceptanceThreshold: calibration.threshold
    )

    let positiveMatch = matcher.bestMatch(profiles: [profile], candidateSamples: syntheticBurst(duration: 0.72, amplitude: 1.02))
    let negativeMatch = matcher.bestMatch(profiles: [profile], candidateSamples: negative[0])

    #expect(calibration.threshold > calibration.positiveMaxDistance)
    #expect(positiveMatch?.shouldTrigger == true)
    #expect(negativeMatch?.shouldTrigger == false)
}

@Test func calibrationReportUsesLeaveOneOutAndHardNegatives() {
    let matcher = MotionTemplateMatcher()
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.04, phase: 0.02)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.02)),
    ]
    let negatives = [templates[0].samples]

    let report = matcher.calibrationReport(
        positiveTemplates: templates,
        negativeWindows: negatives
    )

    #expect(report.positiveRecallEstimate >= 0.66)
    #expect(report.hardNegativeCount > 0)
    #expect(report.recommendedStrictness > 0.55)
}

@Test func singleTemplateCalibrationSupportsMVPTriggering() {
    let matcher = MotionTemplateMatcher()
    let template = MotionTemplate(
        label: "punch",
        kind: .burst,
        samples: syntheticBurst(duration: 0.7, amplitude: 1.0),
        qualityScore: 0.9
    )
    let calibration = matcher.calibrateThreshold(positiveTemplates: [template])
    let profile = GestureProfile(
        name: "punch",
        kind: .burst,
        templates: [template],
        acceptanceThreshold: calibration.threshold
    )

    let match = matcher.bestMatch(
        profiles: [profile],
        candidateSamples: syntheticBurst(duration: 0.76, amplitude: 1.05, phase: 0.04)
    )

    #expect(calibration.threshold >= 0.29)
    #expect(calibration.threshold <= 0.31)
    #expect(match?.shouldTrigger == true)
}

@Test func cooldownSuppressesRepeatedTrigger() {
    let matcher = MotionTemplateMatcher()
    let template = MotionTemplate(
        label: "slash",
        kind: .sequence,
        samples: syntheticSequence(duration: 1.2, amplitude: 1.0),
        qualityScore: 0.9
    )
    let profile = GestureProfile(
        name: "slash",
        kind: .sequence,
        templates: [template],
        acceptanceThreshold: 0.4,
        cooldownSeconds: 1.5
    )

    let blocked = matcher.bestMatch(
        profiles: [profile],
        candidateSamples: syntheticSequence(duration: 1.2, amplitude: 1.0),
        lastTriggerTimes: [profile.id: 10.0],
        now: 10.8
    )

    let allowed = matcher.bestMatch(
        profiles: [profile],
        candidateSamples: syntheticSequence(duration: 1.2, amplitude: 1.0),
        lastTriggerTimes: [profile.id: 10.0],
        now: 12.0
    )

    #expect(blocked == nil)
    #expect(allowed?.shouldTrigger == true)
}

@Test func marginSuppressesAmbiguousTemplateMatch() {
    let matcher = MotionTemplateMatcher()
    let templates = [
        MotionTemplate(label: "swing", kind: .sequence, samples: syntheticSequence(duration: 1.0, amplitude: 1.0), qualityScore: 0.9),
        MotionTemplate(label: "swing", kind: .sequence, samples: syntheticSequence(duration: 1.01, amplitude: 1.01), qualityScore: 0.9),
    ]
    let profile = GestureProfile(
        name: "swing",
        kind: .sequence,
        templates: templates,
        acceptanceThreshold: 0.6,
        marginThreshold: 0.2
    )

    let candidate = matcher.bestMatch(
        profiles: [profile],
        candidateSamples: syntheticSequence(duration: 1.0, amplitude: 1.0)
    )

    #expect(candidate != nil)
    #expect(candidate?.distance ?? 1 < profile.acceptanceThreshold)
    #expect(candidate?.shouldTrigger == false)
}

@Test func ringBufferKeepsOnlyRecentSamples() {
    var buffer = MotionRingBuffer(maxDuration: 0.5)

    for index in 0...10 {
        buffer.append(flatSample(timestamp: Double(index) * 0.1))
    }

    #expect(buffer.samples.first?.timestamp == 0.5)
    #expect(buffer.samples.last?.timestamp == 1.0)
    #expect(buffer.recent(seconds: 0.2).map(\.timestamp) == [0.8, 0.9, 1.0])
}

@Test func energyAnalyzerCalculatesJerkAndFeatures() {
    let analyzer = MotionEnergyAnalyzer()
    let samples = [
        flatSample(timestamp: 0.0, acceleration: 0.1),
        flatSample(timestamp: 0.1, acceleration: 1.1, rotation: 0.4),
        flatSample(timestamp: 0.2, acceleration: 0.2, rotation: 0.1),
    ]

    let frames = analyzer.frames(for: samples)
    let features = analyzer.features(for: samples)

    #expect(frames[0].jerkMagnitude == 0)
    #expect(frames[1].jerkMagnitude > 9)
    #expect(features.peakAcceleration > 1)
    #expect(features.peakJerk > 8)
    #expect(features.energyShape.count == 16)
}

@Test func segmenterExtractsBurstCandidateWithPreroll() {
    var segmenter = MotionGestureSegmenter(configuration: GestureSegmenterConfiguration(
        ringBufferDuration: 2,
        preRollDuration: 0.1,
        postRollDuration: 0.1,
        startEnergyThreshold: 0.5,
        endEnergyThreshold: 0.2,
        endConfirmationDuration: 0.12,
        minimumGestureDuration: 0.1,
        burstMaximumDuration: 0.8,
        cooldownDuration: 0.1
    ))

    var emitted: GestureSegment?
    for sample in burstStream() {
        emitted = segmenter.ingest(sample) ?? emitted
    }

    #expect(emitted != nil)
    #expect(emitted?.kind == .burst)
    #expect((emitted?.duration ?? 0) >= 0.1)
    #expect((emitted?.samples.first?.timestamp ?? 1) < (emitted?.startTimestamp ?? 1))
    #expect((emitted?.peakEnergy ?? 0) > 0.5)
}

@Test func burstGateRejectsWeakBurstBeforeTemplateMatching() {
    let templateBuilder = MotionTemplateBuilder()
    let profile = GestureProfileBuilder().makeProfile(
        name: "punch",
        kind: .burst,
        templates: [
            templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
            templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.02, phase: 0.02)),
            templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.02)),
        ]
    )
    let weakSamples = syntheticBurst(duration: 0.7, amplitude: 0.18)
    let segment = GestureSegment(
        kind: .burst,
        samples: weakSamples,
        startTimestamp: 30,
        endTimestamp: 30.7,
        peakTimestamp: 30.3,
        peakEnergy: 0.2,
        features: MotionEnergyAnalyzer().features(for: weakSamples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 31)

    #expect(event.triggered == false)
    #expect(event.candidate == nil)
    #expect(event.logEntry.bestDistance == nil)
    #expect(event.logEntry.burstGateRejectionReason == .peakAccelerationTooLow)
}

@Test func burstGateDoesNotSuppressSequenceProfiles() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "slash",
        kind: .sequence,
        samples: syntheticSequence(duration: 1.1, amplitude: 1.0)
    )
    let profile = GestureProfile(
        name: "slash",
        kind: .sequence,
        templates: [template],
        acceptanceThreshold: 0.4
    )
    let samples = syntheticSequence(duration: 1.1, amplitude: 1.0)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 40,
        endTimestamp: 41.1,
        peakTimestamp: 40.5,
        peakEnergy: 1.0,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    let strictBurstGate = MotionBurstGate(
        configuration: BurstGateConfiguration(minimumPeakAcceleration: 99)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], burstGate: strictBurstGate, activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 42)

    #expect(event.triggered)
    #expect(event.profile?.id == profile.id)
    #expect(event.logEntry.burstGateRejectionReason == nil)
}

@Test func burstGateCanRejectDominantAxisMismatch() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "punch",
        kind: .burst,
        samples: syntheticBurst(duration: 0.7, amplitude: 1.0)
    )
    let profile = GestureProfile(
        name: "punch",
        kind: .burst,
        templates: [template],
        acceptanceThreshold: 0.5
    )
    let samples = syntheticYAxisBurst(duration: 0.7, amplitude: 0.8)
    let segment = GestureSegment(
        kind: .burst,
        samples: samples,
        startTimestamp: 50,
        endTimestamp: 50.7,
        peakTimestamp: 50.3,
        peakEnergy: 0.8,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    let gate = MotionBurstGate(configuration: BurstGateConfiguration(
        minimumPeakAcceleration: 0.5,
        axisMismatchMinimumPeakAcceleration: 1.2
    ))

    let decision = gate.decision(for: segment, profile: profile)

    #expect(decision.isAllowed == false)
    #expect(decision.reason == .dominantAxisMismatch)
}

@Test func comboProfileRejectsMismatchedSegmentKind() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "punch",
        kind: .combo,
        samples: syntheticSequence(duration: 2.3, amplitude: 2.0)
    )
    let profile = GestureProfile(
        name: "punch",
        kind: .combo,
        templates: [template],
        acceptanceThreshold: 0.6
    )
    let samples = syntheticBurst(duration: 0.5, amplitude: 1.0)
    let segment = GestureSegment(
        kind: .burst,
        samples: samples,
        startTimestamp: 60,
        endTimestamp: 60.5,
        peakTimestamp: 60.25,
        peakEnergy: 1.0,
        features: MotionEnergyAnalyzer().features(for: samples)
    )

    let decision = MotionBurstGate().decision(for: segment, profile: profile)

    #expect(decision.isAllowed == false)
    #expect(decision.reason == .kindMismatch)
}

@Test func comboProfileRejectsWeakTiltLikeMotion() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "punch",
        kind: .combo,
        samples: syntheticSequence(duration: 2.3, amplitude: 2.0)
    )
    let profile = GestureProfile(
        name: "punch",
        kind: .combo,
        templates: [template],
        acceptanceThreshold: 0.6
    )
    let samples = syntheticSequence(duration: 2.0, amplitude: 0.2)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 70,
        endTimestamp: 72,
        peakTimestamp: 71,
        peakEnergy: 0.2,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 72)

    #expect(event.triggered == false)
    #expect(event.candidate == nil)
    #expect(event.logEntry.burstGateRejectionReason == .peakAccelerationTooLow)
}

@Test func comboProfileRejectsOverlongMotion() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "punch",
        kind: .combo,
        samples: syntheticSequence(duration: 2.3, amplitude: 2.0)
    )
    let profile = GestureProfile(
        name: "punch",
        kind: .combo,
        templates: [template],
        acceptanceThreshold: 0.6
    )
    let samples = syntheticSequence(duration: 7.0, amplitude: 2.0)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 80,
        endTimestamp: 87,
        peakTimestamp: 83,
        peakEnergy: 2.0,
        features: MotionEnergyAnalyzer().features(for: samples)
    )

    let decision = MotionBurstGate().decision(for: segment, profile: profile)

    #expect(decision.isAllowed == false)
    #expect(decision.reason == .durationTooLong)
}

@Test func recognitionLogEntryRoundTripsThroughJSON() throws {
    let profileID = UUID()
    let entry = RecognitionLogEntry(
        timestamp: 12.3,
        gestureKindDetected: .burst,
        duration: 0.42,
        peakAcceleration: 1.4,
        peakRotationRate: 0.8,
        bestProfileID: profileID,
        bestDistance: 0.12,
        secondBestDistance: 0.41,
        threshold: 0.2,
        margin: 0.29,
        triggered: true,
        audioPlayed: true,
        batteryLevel: 0.82,
        wearContext: WearContext(wristLocation: "left", crownOrientation: "right")
    )

    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(RecognitionLogEntry.self, from: data)

    #expect(decoded == entry)
}

@Test func tokenizerEmitsFullSegmentAndSlidingWindowTokens() {
    let samples = syntheticRotation(duration: 1.4, angle: .pi * 2.1)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: samples.first?.timestamp ?? 0,
        endTimestamp: samples.last?.timestamp ?? 1.4,
        peakTimestamp: 0.7,
        peakEnergy: 1,
        features: MotionEnergyAnalyzer().features(for: samples)
    )

    let tokens = MotionTokenizer(windowDuration: 0.8, hopDuration: 0.4).tokenize(segment: segment)

    #expect(tokens.count > 1)
    #expect(tokens.first?.startTime == segment.startTimestamp)
    #expect(tokens.first?.endTime == segment.endTimestamp)
    #expect(tokens.dropFirst().contains { $0.kind == .rotation && $0.confidence > 0 })
}

@Test func profileSyncManifestAndAckRoundTripThroughJSON() throws {
    let transactionID = UUID()
    let manifest = ProfileSyncManifest(
        transactionID: transactionID,
        libraryVersion: "lib-test",
        profileCount: 2,
        profileFileName: "gesture_profiles.json",
        profileChecksum: "abc123",
        audioChecksumsByFileName: ["sound.wav": "def456"],
        sentAt: Date(timeIntervalSince1970: 10)
    )
    let ack = ProfileSyncAck(
        transactionID: transactionID,
        libraryVersion: "lib-test",
        applied: false,
        profileCount: 2,
        missingAudioFileNames: ["sound.wav"],
        reason: "missingAudio",
        sentAt: Date(timeIntervalSince1970: 11)
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let decodedManifest = try decoder.decode(ProfileSyncManifest.self, from: encoder.encode(manifest))
    let decodedAck = try decoder.decode(ProfileSyncAck.self, from: encoder.encode(ack))

    #expect(decodedManifest == manifest)
    #expect(decodedAck == ack)
}

@Test func templateBuilderAttachesFeaturesAndQuality() {
    let builder = MotionTemplateBuilder()
    let samples = syntheticBurst(duration: 0.7, amplitude: 1.1)

    let template = builder.makeTemplate(label: "punch", kind: .burst, samples: samples)

    #expect(template.rawDuration > 0.65)
    #expect(template.sampleRate > 40)
    #expect(template.features?.peakAcceleration ?? 0 > 1)
    #expect(template.features?.energyShape.count == 16)
    #expect(template.qualityScore > 0.5)
}

@Test func profileBuilderUsesNegativeSamplesForThresholdAndQuality() {
    let templateBuilder = MotionTemplateBuilder()
    let profileBuilder = GestureProfileBuilder()
    let positives = [
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.74, amplitude: 1.03, phase: 0.03)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.04)),
    ]
    let negatives = [
        templateBuilder.makeTemplate(label: "daily", kind: .sequence, samples: syntheticSequence(duration: 0.7, amplitude: 1.0))
    ]

    let profile = profileBuilder.makeProfile(
        name: "punch",
        kind: .burst,
        templates: positives,
        negativeTemplates: negatives,
        sound: SoundAsset(fileName: "punch.wav", duration: 0.4, checksum: "abc"),
        wearContext: WearContext(wristLocation: "left", crownOrientation: "right")
    )

    #expect(profile.templates.count == 3)
    #expect(profile.negativeTemplates.count == 1)
    #expect(profile.acceptanceThreshold > 0)
    #expect(profile.marginThreshold >= 0)
    #expect(profile.quality.score > 0.4)
    #expect(profile.triggerTiming == .atPeak)
    #expect(profile.sound?.checksum == "abc")
}

@Test func profileBuilderCreatesStandardProfileFromThreePositiveTemplates() {
    let templateBuilder = MotionTemplateBuilder()
    let templates = [
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.02, phase: 0.02)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.69, amplitude: 0.98, phase: -0.02)),
    ]
    let negative = templateBuilder.makeTemplate(
        label: "daily-negative",
        kind: .burst,
        samples: syntheticSequence(duration: 0.72, amplitude: 1.0)
    )

    let profile = GestureProfileBuilder().makeProfile(
        name: "punch",
        kind: .burst,
        templates: templates,
        negativeTemplates: [negative],
        sound: SoundAsset(fileName: "punch.wav", duration: 0.35)
    )
    let negativeCandidate = MotionTemplateMatcher().bestMatch(
        profiles: [profile],
        candidateSamples: negative.samples
    )

    #expect(profile.templates.count == 3)
    #expect(profile.negativeTemplates.count == 1)
    #expect(profile.acceptanceThreshold > 0)
    #expect(profile.marginThreshold >= 0)
    #expect(profile.quality.score > 0.55)
    #expect(!profile.quality.warnings.contains { $0.contains("仅录制 1 次") })
    #expect(profile.sound?.fileName == "punch.wav")
    #expect(negativeCandidate?.shouldTrigger == false)
}

@Test func qualityEvaluatorFlagsSingleTemplateAsLowReliability() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "single",
        kind: .burst,
        samples: syntheticBurst(duration: 0.5, amplitude: 0.8)
    )

    let report = GestureQualityEvaluator().evaluate(templates: [template])

    #expect(report.reliability != .high)
    #expect(report.warnings.contains { $0.contains("仅录制 1 次") })
}

@Test func profileArchiveRoundTripsThroughCodec() throws {
    let templateBuilder = MotionTemplateBuilder()
    let profileBuilder = GestureProfileBuilder()
    let templates = [
        templateBuilder.makeTemplate(label: "slash", kind: .sequence, samples: syntheticSequence(duration: 1.0, amplitude: 1.0)),
        templateBuilder.makeTemplate(label: "slash", kind: .sequence, samples: syntheticSequence(duration: 1.1, amplitude: 1.03)),
    ]
    let profile = profileBuilder.makeProfile(name: "slash", kind: .sequence, templates: templates)
    let archive = GestureProfileArchive(profiles: [profile])
    let codec = GestureProfileCodec()

    let data = try codec.encode(archive)
    let decoded = try codec.decode(data)

    #expect(decoded.profiles.count == 1)
    #expect(decoded.profiles[0].name == "slash")
    #expect(decoded.profiles[0].templates.count == 2)
}

@Test func profileCodecBackfillsStageAndPoseSignaturesForStoredProfiles() throws {
    let templateBuilder = MotionTemplateBuilder()
    let templates = [
        templateBuilder.makeTemplate(label: "eye-pose", kind: .burst, samples: syntheticPoseImpulse(duration: 1.25, endGravity: MotionVector3(x: 0, y: -1, z: 0), terminalHold: 0.32)),
        templateBuilder.makeTemplate(label: "eye-pose", kind: .burst, samples: syntheticPoseImpulse(duration: 1.28, endGravity: MotionVector3(x: 0.03, y: -0.99, z: 0), terminalHold: 0.34)),
        templateBuilder.makeTemplate(label: "eye-pose", kind: .burst, samples: syntheticPoseImpulse(duration: 1.22, endGravity: MotionVector3(x: -0.03, y: -0.99, z: 0), terminalHold: 0.30)),
    ]
    var profile = GestureProfileBuilder().makeProfile(name: "eye-pose", kind: .burst, templates: templates)
    profile.signature?.stages = nil
    profile.signature?.pose = nil
    profile.thresholds = nil
    let archive = GestureProfileArchive(profiles: [profile])
    let codec = GestureProfileCodec()

    let decoded = try codec.decode(try codec.encode(archive))
    let upgraded = decoded.profiles[0]

    #expect(upgraded.signature?.stages?.contains { $0.kind == .hold } == true)
    #expect(upgraded.signature?.pose != nil)
    #expect(upgraded.thresholds != nil)
}

@Test func profileCodecMigratesStoredRotationProfileKindAndThresholds() throws {
    let templateBuilder = MotionTemplateBuilder()
    let templates = [
        templateBuilder.makeTemplate(label: "turn", kind: .burst, samples: syntheticRotation(duration: 1.2, angle: .pi * 2.0)),
        templateBuilder.makeTemplate(label: "turn", kind: .burst, samples: syntheticRotation(duration: 1.3, angle: .pi * 2.05)),
        templateBuilder.makeTemplate(label: "turn", kind: .burst, samples: syntheticRotation(duration: 1.1, angle: .pi * 1.95)),
    ]
    var profile = GestureProfileBuilder().makeProfile(name: "turn", kind: .burst, templates: templates)
    profile.thresholds = ThresholdProfile(triggerScore: 0.70, rejectScore: 0.48, marginScore: 0.08)
    let archive = GestureProfileArchive(profiles: [profile])
    let codec = GestureProfileCodec()

    let decoded = try codec.decode(try codec.encode(archive))
    let upgraded = decoded.profiles[0]

    #expect(upgraded.kind == .sequence)
    #expect(upgraded.signature?.primaryKind == .rotation)
    #expect((upgraded.thresholds?.triggerScore ?? 1) <= 0.62)
}

@Test func profileArchivePreservesSoundSequence() throws {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "combo",
        kind: .sequence,
        samples: syntheticSequence(duration: 1.2, amplitude: 1.0)
    )
    var profile = GestureProfileBuilder().makeProfile(
        name: "combo",
        kind: .sequence,
        templates: [template],
        sound: SoundAsset(fileName: "第1次.wav", duration: 0.3)
    )
    profile.soundSequence = [
        SoundAsset(fileName: "第1次.wav", duration: 0.3),
        SoundAsset(fileName: "第2次.wav", duration: 0.4),
        SoundAsset(fileName: "第3次.mp3", duration: 0.5),
    ]
    let archive = GestureProfileArchive(profiles: [profile])
    let codec = GestureProfileCodec()

    let decoded = try codec.decode(try codec.encode(archive))

    #expect(decoded.profiles[0].sound?.fileName == "第1次.wav")
    #expect(decoded.profiles[0].soundSequence?.map(\.fileName) == ["第1次.wav", "第2次.wav", "第3次.mp3"])
}

@Test func signatureBuilderClassifiesRotationProfile() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "turn",
        kind: .sequence,
        samples: syntheticRotation(duration: 1.2, angle: .pi * 2)
    )
    let profile = GestureProfileBuilder().makeProfile(
        name: "turn",
        kind: .sequence,
        templates: [
            template,
            MotionTemplateBuilder().makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.25, angle: .pi * 2.04)),
            MotionTemplateBuilder().makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.18, angle: .pi * 1.98)),
        ]
    )

    #expect(profile.signature?.primaryKind == .rotation)
    #expect((profile.signature?.rotation?.totalAngleRadians ?? 0) > .pi * 1.5)
    #expect(profile.thresholds?.minAngle != nil)
}

@Test func rotationRecognizerAcceptsSlowerSameCircle() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "turn",
        kind: .sequence,
        samples: syntheticRotation(duration: 1.2, angle: .pi * 2)
    )
    let profile = GestureProfileBuilder().makeProfile(
        name: "turn",
        kind: .sequence,
        templates: [
            template,
            MotionTemplateBuilder().makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.25, angle: .pi * 2.04)),
            MotionTemplateBuilder().makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.18, angle: .pi * 1.98)),
        ]
    )
    let samples = syntheticRotation(duration: 3.0, angle: .pi * 2.05)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 10,
        endTimestamp: 13,
        peakTimestamp: 11.5,
        peakEnergy: 0.8,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 13.1)

    #expect(event.triggered)
    #expect(event.candidate?.recognizerKind == .rotation)
    #expect(event.logEntry.classifiedKind == .rotation)
    #expect(event.logEntry.tokens.first?.integratedAngle ?? 0 > .pi * 1.5)
}

@Test func continuousEpisodeRecognizerTriggersRotationBeforeSegmentFinalizes() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "turn",
        kind: .sequence,
        samples: syntheticRotation(duration: 1.2, angle: .pi * 2)
    )
    let profile = GestureProfileBuilder().makeProfile(
        name: "turn",
        kind: .sequence,
        templates: [
            template,
            MotionTemplateBuilder().makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.25, angle: .pi * 2.04)),
            MotionTemplateBuilder().makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.18, angle: .pi * 1.98)),
        ]
    )
    let interval = 0.02
    var stream: [MotionSample] = (0..<10).map {
        flatSample(timestamp: Double($0) * interval, acceleration: 0.01, rotation: 0.01)
    }
    let offset = (stream.last?.timestamp ?? 0) + interval
    stream.append(contentsOf: syntheticRotation(duration: 1.36, angle: .pi * 2.08).map {
        MotionSample(
            timestamp: $0.timestamp + offset,
            userAcceleration: $0.userAcceleration,
            rotationRate: $0.rotationRate,
            gravity: $0.gravity,
            attitude: $0.attitude
        )
    })
    var runtime = GestureRecognitionRuntime(
        profiles: [profile],
        continuousEvaluationInterval: 0.08,
        activeRecognitionSelection: .allProfiles
    )
    var triggered: ContinuousRecognitionEvaluation?

    for sample in stream {
        if let evaluation = runtime.evaluateContinuous(sample: sample, now: sample.timestamp) {
            if evaluation.evaluation.candidate?.shouldTrigger == true {
                triggered = evaluation
                break
            }
        }
    }

    #expect(triggered != nil)
    #expect(triggered?.evaluation.candidate?.profile.id == profile.id)
    #expect(triggered?.evaluation.candidate?.recognizerKind == .rotation)
    #expect((triggered?.evaluation.tokens.first?.integratedAngle ?? 0) > .pi * 1.5)
}

@Test func continuousEpisodeRecognizerDoesNotEmitRejectedCandidates() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "turn",
        kind: .sequence,
        samples: syntheticRotation(duration: 1.2, angle: .pi * 2)
    )
    let profile = GestureProfileBuilder().makeProfile(name: "turn", kind: .sequence, templates: [template])
    let stream = syntheticRotation(duration: 2.0, angle: .pi * 1.05)
    var runtime = GestureRecognitionRuntime(
        profiles: [profile],
        continuousEvaluationInterval: 0.02,
        activeRecognitionSelection: .allProfiles
    )
    var emitted: ContinuousRecognitionEvaluation?

    for sample in stream {
        if let evaluation = runtime.evaluateContinuous(sample: sample, now: sample.timestamp) {
            emitted = evaluation
            break
        }
    }

    #expect(emitted == nil)
}

@Test func rotationRecognizerRejectsHighAngleBackAndForthMotion() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "turn",
        kind: .sequence,
        samples: syntheticRotation(duration: 1.4, angle: .pi * 2)
    )
    let profile = GestureProfileBuilder().makeProfile(name: "turn", kind: .sequence, templates: [template])
    let samples = syntheticOscillatingRotation(duration: 2.3, angle: .pi * 2.05)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 20,
        endTimestamp: 22.3,
        peakTimestamp: 21.1,
        peakEnergy: 0.9,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 22.4)

    #expect(event.triggered == false)
    #expect(event.logEntry.rejectReason == .rotationDirectionMismatch)
    #expect((event.logEntry.tokens.first?.integratedAngle ?? 0) > .pi * 1.5)
    #expect(MotionFeatureExtractor().extract(samples).rotationDirectionConsistency < 0.55)
}

@Test func continuousEpisodeRecognizerUsesFullLibraryCompetition() {
    let builder = MotionTemplateBuilder()
    let turnProfile = GestureProfileBuilder().makeProfile(
        name: "turn",
        kind: .sequence,
        templates: [
            builder.makeTemplate(label: "turn-a", kind: .sequence, samples: syntheticRotation(duration: 1.2, angle: .pi * 2.0)),
            builder.makeTemplate(label: "turn-b", kind: .sequence, samples: syntheticRotation(duration: 1.25, angle: .pi * 2.04)),
            builder.makeTemplate(label: "turn-c", kind: .sequence, samples: syntheticRotation(duration: 1.18, angle: .pi * 1.96)),
        ]
    )
    let nearTurnProfile = GestureProfileBuilder().makeProfile(
        name: "near-turn",
        kind: .sequence,
        templates: [
            builder.makeTemplate(label: "near-turn-a", kind: .sequence, samples: syntheticRotation(duration: 1.23, angle: .pi * 2.02)),
            builder.makeTemplate(label: "near-turn-b", kind: .sequence, samples: syntheticRotation(duration: 1.27, angle: .pi * 2.05)),
            builder.makeTemplate(label: "near-turn-c", kind: .sequence, samples: syntheticRotation(duration: 1.19, angle: .pi * 1.98)),
        ]
    )
    let stream = syntheticRotation(duration: 1.42, angle: .pi * 2.03)
    var runtime = GestureRecognitionRuntime(
        profiles: [turnProfile, nearTurnProfile],
        continuousEvaluationInterval: 0.18,
        activeRecognitionSelection: .allProfiles
    )
    var emitted: ContinuousRecognitionEvaluation?

    for sample in stream {
        if let evaluation = runtime.evaluateContinuous(sample: sample, now: sample.timestamp) {
            emitted = evaluation
            break
        }
    }

    #expect(emitted == nil)
}

@Test func trajectoryRecognizerTreatsDistanceThresholdAsTriggerBoundary() {
    let builder = MotionTemplateBuilder()
    var profile = GestureProfileBuilder().makeProfile(
        name: "turn",
        kind: .sequence,
        templates: [
            builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.2, angle: .pi * 2.0)),
            builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.25, angle: .pi * 2.04)),
            builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.18, angle: .pi * 1.98)),
        ]
    )
    let samples = syntheticRotation(duration: 1.55, angle: .pi * 2.08)
    let measuredDistance = MotionTemplateMatcher()
        .bestMatch(profiles: [profile], candidateSamples: samples)?
        .distance ?? 0.2
    profile.acceptanceThreshold = measuredDistance + 0.002
    var thresholds = profile.thresholds ?? ThresholdProfile()
    thresholds.triggerScore = 0.66
    thresholds.rejectScore = 0.40
    profile.thresholds = thresholds
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 50,
        endTimestamp: 51.55,
        peakTimestamp: 50.8,
        peakEnergy: 0.8,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 51.6)

    #expect((event.candidate?.distance ?? .infinity) <= profile.acceptanceThreshold)
    #expect(event.triggered)
    #expect((event.candidate?.recognitionScore ?? 0) >= (event.profile?.thresholds?.triggerScore ?? .infinity))
}

@Test func trajectoryRecognizerAllowsNearMissDistanceWhenSemanticScoreIsStrong() {
    let builder = MotionTemplateBuilder()
    var profile = GestureProfileBuilder().makeProfile(
        name: "turn",
        kind: .sequence,
        templates: [
            builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.2, angle: .pi * 2.0)),
            builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.25, angle: .pi * 2.04)),
            builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.18, angle: .pi * 1.98)),
        ]
    )
    let samples = syntheticRotation(duration: 1.55, angle: .pi * 2.08)
    let measuredDistance = MotionTemplateMatcher()
        .bestMatch(profiles: [profile], candidateSamples: samples)?
        .distance ?? 0.2
    profile.acceptanceThreshold = measuredDistance * 0.90
    var thresholds = profile.thresholds ?? ThresholdProfile()
    thresholds.triggerScore = 0.64
    thresholds.rejectScore = 0.40
    profile.thresholds = thresholds
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 50,
        endTimestamp: 51.55,
        peakTimestamp: 50.8,
        peakEnergy: 0.8,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 51.6)

    #expect((event.candidate?.distance ?? 0) > profile.acceptanceThreshold)
    #expect(event.triggered)
    #expect(event.logEntry.rejectReason == nil)
}

@Test func runtimeRecoversEarlierSamplesForCompleteTrajectoryMatch() {
    let builder = MotionTemplateBuilder()
    let samples = syntheticSequence(duration: 1.2, amplitude: 1.0)
    var profile = GestureProfileBuilder().makeProfile(
        name: "slash",
        kind: .sequence,
        templates: [
            builder.makeTemplate(label: "slash", kind: .sequence, samples: samples),
            builder.makeTemplate(label: "slash", kind: .sequence, samples: syntheticSequence(duration: 1.22, amplitude: 1.03)),
            builder.makeTemplate(label: "slash", kind: .sequence, samples: syntheticSequence(duration: 1.18, amplitude: 0.98)),
        ]
    )
    let fullDistance = MotionTemplateMatcher()
        .bestMatch(profiles: [profile], candidateSamples: samples)?
        .distance ?? 0
    profile.acceptanceThreshold = fullDistance + 0.08
    var thresholds = profile.thresholds ?? ThresholdProfile()
    thresholds.triggerScore = 0.62
    thresholds.marginScore = 0.04
    profile.thresholds = thresholds
    let suffix = samples.filter { $0.timestamp >= 0.58 }
    let suffixDistance = MotionTemplateMatcher()
        .bestMatch(profiles: [profile], candidateSamples: suffix)?
        .distance ?? 0
    let partialSegment = GestureSegment(
        kind: .sequence,
        samples: suffix,
        startTimestamp: suffix.first?.timestamp ?? 0.58,
        endTimestamp: suffix.last?.timestamp ?? 1.2,
        peakTimestamp: suffix.first?.timestamp ?? 0.58,
        peakEnergy: 1.0,
        features: MotionEnergyAnalyzer().features(for: suffix)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], continuousEvaluationInterval: 99, activeRecognitionSelection: .allProfiles)

    for sample in samples {
        _ = runtime.evaluateContinuous(sample: sample, now: sample.timestamp)
    }
    let event = runtime.recognize(segment: partialSegment, now: samples.last?.timestamp ?? 1.2)

    #expect(suffixDistance > fullDistance + 0.10)
    #expect(event.triggered)
    #expect(event.candidate?.profile.id == profile.id)
}

@Test func rotationRecognizerExplainsAngleTooSmallRejection() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "turn",
        kind: .sequence,
        samples: syntheticRotation(duration: 1.2, angle: .pi * 2)
    )
    let profile = GestureProfileBuilder().makeProfile(name: "turn", kind: .sequence, templates: [template])
    let samples = syntheticRotation(duration: 1.0, angle: .pi * 0.35)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 20,
        endTimestamp: 21,
        peakTimestamp: 20.5,
        peakEnergy: 0.2,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 21.1)

    #expect(event.triggered == false)
    #expect(event.candidate?.recognizerKind == .rotation)
    #expect(event.logEntry.rejectReason == .rotationAngleTooSmall)
    #expect(event.logEntry.candidateReports.first?.rejectReason == .rotationAngleTooSmall)
}

@Test func rotationRecognizerRejectsDifferentRotationAxis() {
    let template = MotionTemplateBuilder().makeTemplate(
        label: "turn-z",
        kind: .sequence,
        samples: syntheticRotation(duration: 1.2, angle: .pi * 2, axis: 2)
    )
    let profile = GestureProfileBuilder().makeProfile(name: "turn-z", kind: .sequence, templates: [template])
    let samples = syntheticRotation(duration: 1.2, angle: .pi * 2, axis: 0)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 30,
        endTimestamp: 31.2,
        peakTimestamp: 30.6,
        peakEnergy: 0.8,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 31.3)

    #expect(event.triggered == false)
    #expect(event.candidate?.recognizerKind == .rotation)
    #expect(event.logEntry.rejectReason == .rotationAxisUnstable)
}

@Test func signatureProfilesRequireRuntimeMarginForSingleTemplate() {
    let builder = MotionTemplateBuilder()
    let xProfile = GestureProfileBuilder().makeProfile(
        name: "turn-x",
        kind: .sequence,
        templates: [builder.makeTemplate(label: "turn-x", kind: .sequence, samples: syntheticRotation(duration: 1.2, angle: .pi * 2, axis: 0))]
    )
    let nearXProfile = GestureProfileBuilder().makeProfile(
        name: "turn-x-near",
        kind: .sequence,
        templates: [builder.makeTemplate(label: "turn-x-near", kind: .sequence, samples: syntheticRotation(duration: 1.3, angle: .pi * 2.05, axis: 0))]
    )
    let samples = syntheticRotation(duration: 1.25, angle: .pi * 2.02, axis: 0)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 40,
        endTimestamp: 41.25,
        peakTimestamp: 40.6,
        peakEnergy: 0.8,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [xProfile, nearXProfile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 41.3)

    #expect(event.triggered == false)
    #expect(event.candidate?.rejectReason == .marginTooSmall)
    #expect(event.logEntry.rejectReason == .marginTooSmall)
}

@Test func hardTrajectoryRejectDoesNotBlockMatchingImpulse() {
    let builder = MotionTemplateBuilder()
    let punchProfile = GestureProfileBuilder().makeProfile(
        name: "punch",
        kind: .burst,
        templates: [
            builder.makeTemplate(label: "punch-a", kind: .burst, samples: syntheticBurst(duration: 1.0, amplitude: 5.0)),
            builder.makeTemplate(label: "punch-b", kind: .burst, samples: syntheticBurst(duration: 1.05, amplitude: 5.2, phase: 0.02)),
            builder.makeTemplate(label: "punch-c", kind: .burst, samples: syntheticBurst(duration: 0.96, amplitude: 4.8, phase: -0.02)),
        ]
    )
    let eyePoseProfile = GestureProfileBuilder().makeProfile(
        name: "eye-pose",
        kind: .burst,
        templates: [
            builder.makeTemplate(label: "eye-a", kind: .burst, samples: syntheticYAxisBurst(duration: 1.0, amplitude: 5.0)),
            builder.makeTemplate(label: "eye-b", kind: .burst, samples: syntheticYAxisBurst(duration: 1.04, amplitude: 5.15)),
            builder.makeTemplate(label: "eye-c", kind: .burst, samples: syntheticYAxisBurst(duration: 0.88, amplitude: 4.85)),
        ]
    )
    let samples = syntheticBurst(duration: 0.82, amplitude: 5.1, phase: 0.01)
    let segment = GestureSegment(
        kind: .burst,
        samples: samples,
        startTimestamp: 70,
        endTimestamp: 70.82,
        peakTimestamp: 70.44,
        peakEnergy: 3.5,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [punchProfile, eyePoseProfile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 70.9)

    #expect(event.triggered)
    #expect(event.profile?.name == "punch")
    let wrongReport = event.logEntry.candidateReports.first { $0.profileName == "eye-pose" }
    #expect(wrongReport?.rejectReason == .trajectoryDistanceTooHigh || wrongReport?.rejectReason == .impulseDirectionMismatch)
    #expect((wrongReport?.score ?? 1) <= 0.34)
}

@Test func profileFileStoreSavesListsLoadsAndDeletesArchives() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MotionSoundCoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = GestureProfileFileStore(directoryURL: root)
    let template = MotionTemplateBuilder().makeTemplate(
        label: "punch",
        kind: .burst,
        samples: syntheticBurst(duration: 0.6, amplitude: 1.0)
    )
    let profile = GestureProfileBuilder().makeProfile(
        name: "挥拳 / punch",
        kind: .burst,
        templates: [template]
    )
    let archive = GestureProfileArchive(
        libraryVersion: "test-library-1",
        profiles: [profile],
        exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let fileURL = try store.save(archive, preferredName: profile.name)
    let listed = try store.list()
    let loaded = try store.load(from: fileURL)

    #expect(fileURL.lastPathComponent.contains("punch"))
    #expect(fileURL.pathExtension == "json")
    #expect(listed.count == 1)
    #expect(loaded.libraryVersion == "test-library-1")
    #expect(loaded.profiles.first?.name == "挥拳 / punch")

    try store.delete(fileURL: fileURL)
    #expect(try store.list().isEmpty)
}

@Test func profileLibraryVersionIgnoresGeneratedRuntimeFields() {
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.2, angle: .pi * 2)),
        builder.makeTemplate(label: "turn", kind: .sequence, samples: syntheticRotation(duration: 1.25, angle: .pi * 2.04)),
    ]
    let profile = GestureProfileBuilder().makeProfile(
        name: "turn",
        kind: .sequence,
        templates: templates,
        sound: SoundAsset(fileName: "日语-成功.wav", duration: 0.4, volume: 1)
    )
    var regenerated = profile
    regenerated.updatedAt = Date(timeIntervalSince1970: 2_000_000_000)
    regenerated.createdAt = Date(timeIntervalSince1970: 1_900_000_000)
    regenerated.quality = GestureQuality(score: 0.12, warnings: ["runtime-only"])
    regenerated.signatureVariants = GestureProfileVariantBuilder().makeVariants(
        templates: templates,
        strictness: 0.5
    )

    let firstVersion = GestureProfileLibraryVersion.make(profiles: [profile])
    let secondVersion = GestureProfileLibraryVersion.make(profiles: [regenerated])

    #expect(firstVersion == secondVersion)
}

@Test func motionSampleCSVCodecExportsStableDiagnosticColumns() {
    let samples = [
        MotionSample(
            timestamp: 0,
            userAcceleration: MotionVector3(x: 0.1, y: 0.2, z: 0.3),
            rotationRate: MotionVector3(x: 1.1, y: 1.2, z: 1.3),
            gravity: MotionVector3(x: -0.1, y: -0.2, z: -0.3),
            attitude: MotionQuaternion(x: 0.4, y: 0.5, z: 0.6, w: 0.7)
        ),
        MotionSample(
            timestamp: 0.02,
            userAcceleration: MotionVector3(x: 0, y: 0, z: 0),
            rotationRate: MotionVector3(x: 0, y: 0, z: 0)
        )
    ]

    let csv = MotionSampleCSVCodec().encode(samples)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

    #expect(lines.first == "timestamp,userAccelerationX,userAccelerationY,userAccelerationZ,rotationRateX,rotationRateY,rotationRateZ,gravityX,gravityY,gravityZ,attitudeX,attitudeY,attitudeZ,attitudeW")
    #expect(lines[1].contains("0.100000000,0.200000000,0.300000000"))
    #expect(lines[1].contains("-0.100000000,-0.200000000,-0.300000000"))
    #expect(lines[2].hasSuffix(",,,,,,,"))
}

@Test func motionSampleCSVCodecDecodesExportedSamples() throws {
    let samples = [
        MotionSample(
            timestamp: 0,
            userAcceleration: MotionVector3(x: 0.1, y: 0.2, z: 0.3),
            rotationRate: MotionVector3(x: 1.1, y: 1.2, z: 1.3),
            gravity: MotionVector3(x: -0.1, y: -0.2, z: -0.3),
            attitude: MotionQuaternion(x: 0.4, y: 0.5, z: 0.6, w: 0.7)
        ),
        MotionSample(
            timestamp: 0.02,
            userAcceleration: MotionVector3(x: 0, y: 0, z: 0),
            rotationRate: MotionVector3(x: 0, y: 0, z: 0)
        )
    ]
    let codec = MotionSampleCSVCodec()

    let decoded = try codec.decode(codec.encode(samples))

    #expect(decoded.count == 2)
    #expect(decoded[0].userAcceleration == samples[0].userAcceleration)
    #expect(decoded[0].gravity == samples[0].gravity)
    #expect(decoded[0].attitude == samples[0].attitude)
    #expect(decoded[1].gravity == nil)
    #expect(decoded[1].attitude == nil)
}

@Test func motionRecordingFileStoreSavesAndListsCSV() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MotionRecordingFileStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MotionRecordingFileStore(directoryURL: root)
    let samples = syntheticBurst(duration: 0.3, amplitude: 1.0)

    let url = try store.save(
        samples,
        preferredName: "挥拳 / punch",
        exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let listed = try store.list()
    let csv = try String(contentsOf: url, encoding: .utf8)

    #expect(url.lastPathComponent.contains("punch"))
    #expect(url.pathExtension == "csv")
    #expect(listed.map(\.lastPathComponent) == [url.lastPathComponent])
    #expect(csv.contains("timestamp,userAccelerationX"))
    #expect(csv.split(separator: "\n").count == samples.count + 1)
}

@Test func recognitionRuntimeTriggersMatchingProfileAndLogsEvent() {
    let templateBuilder = MotionTemplateBuilder()
    let profileBuilder = GestureProfileBuilder()
    let templates = [
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.73, amplitude: 1.04, phase: 0.03)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.97, phase: -0.03)),
    ]
    let profile = profileBuilder.makeProfile(name: "punch", kind: .burst, templates: templates)
    let segment = GestureSegment(
        kind: .burst,
        samples: syntheticBurst(duration: 0.71, amplitude: 1.02),
        startTimestamp: 10,
        endTimestamp: 10.71,
        peakTimestamp: 10.32,
        peakEnergy: 1.2,
        features: MotionEnergyAnalyzer().features(for: syntheticBurst(duration: 0.71, amplitude: 1.02))
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(
        segment: segment,
        now: 10.8,
        batteryLevel: 0.7,
        wearContext: WearContext(wristLocation: "left", crownOrientation: "right"),
        audioPlayed: true
    )

    #expect(event.triggered)
    #expect(event.profile?.id == profile.id)
    #expect(runtime.logs.count == 1)
    #expect(runtime.logs[0].audioPlayed)
    #expect(runtime.logs[0].bestProfileID == profile.id)
    #expect(runtime.lastTriggerTimes[profile.id] == 10.8)
}

@Test func recognitionRuntimeOnlyEvaluatesActiveProfiles() {
    let templateBuilder = MotionTemplateBuilder()
    let profileBuilder = GestureProfileBuilder()
    let templates = [
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.70, amplitude: 1.0)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.73, amplitude: 1.03, phase: 0.03)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.97, phase: -0.03)),
    ]
    let activeProfile = profileBuilder.makeProfile(name: "active-punch", kind: .burst, templates: templates)
    let inactiveProfile = profileBuilder.makeProfile(name: "inactive-punch", kind: .burst, templates: templates)
    let samples = syntheticBurst(duration: 0.71, amplitude: 1.02)
    let segment = GestureSegment(
        kind: .burst,
        samples: samples,
        startTimestamp: 20,
        endTimestamp: 20.71,
        peakTimestamp: 20.32,
        peakEnergy: 1.2,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(
        profiles: [activeProfile, inactiveProfile],
        activeRecognitionSelection: .inactive
    )

    let noActiveEvaluation = runtime.evaluate(segment: segment, now: 20.8)
    #expect(noActiveEvaluation.candidate == nil)
    #expect(noActiveEvaluation.rejectReason == .noActiveProfile)

    runtime.setActiveProfileIDs([activeProfile.id])
    let activeEvaluation = runtime.evaluate(segment: segment, now: 20.9)
    #expect(activeEvaluation.candidate?.profile.id == activeProfile.id)
    #expect(activeEvaluation.candidate?.shouldTrigger == true)
    #expect(activeEvaluation.candidate?.rejectReason != .marginTooSmall)
    #expect(activeEvaluation.candidateReports.map(\.profileID) == [activeProfile.id])

    runtime.setActiveProfileIDs([inactiveProfile.id])
    let switchedEvaluation = runtime.evaluate(segment: segment, now: 21.0)
    #expect(switchedEvaluation.candidate?.profile.id == inactiveProfile.id)
    #expect(switchedEvaluation.candidateReports.map(\.profileID) == [inactiveProfile.id])
}

@Test func lowPassFilterSuppressesHighFrequencyNoiseButKeepsShape() {
    // 在干净 burst 上叠加高频噪声，滤波后应更接近原始干净信号。
    let clean = syntheticBurst(duration: 0.8, amplitude: 1.0)
    var rngState: UInt64 = 0x9E3779B97F4A7C15
    func noise() -> Double {
        // 确定性伪随机（不依赖 Math.random），范围约 [-0.15, 0.15]。
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        return (Double(rngState >> 40) / Double(1 << 24) - 0.5) * 0.30
    }
    let noisy = clean.map { sample in
        MotionSample(
            timestamp: sample.timestamp,
            userAcceleration: MotionVector3(
                x: sample.userAcceleration.x + noise(),
                y: sample.userAcceleration.y + noise(),
                z: sample.userAcceleration.z + noise()
            ),
            rotationRate: sample.rotationRate
        )
    }
    let filter = MotionLowPassFilter(cutoffHz: 8)
    let filtered = filter.filtered(noisy)

    func meanAbsErr(_ a: [MotionSample], _ b: [MotionSample]) -> Double {
        zip(a, b).map { abs($0.userAcceleration.x - $1.userAcceleration.x) }
            .reduce(0, +) / Double(a.count)
    }
    let rawErr = meanAbsErr(noisy, clean)
    let filteredErr = meanAbsErr(filtered, clean)
    #expect(filteredErr < rawErr)
    #expect(filtered.count == noisy.count)
    // 滤波保持时间戳不变。
    #expect(filtered.first?.timestamp == noisy.first?.timestamp)
    #expect(filtered.last?.timestamp == noisy.last?.timestamp)
}

@Test func lowPassFilterIsIdentityForTinyOrDisabledInput() {
    let tiny = Array(syntheticBurst(duration: 0.8, amplitude: 1.0).prefix(3))
    #expect(MotionLowPassFilter().filtered(tiny) == tiny)
    let full = syntheticBurst(duration: 0.8, amplitude: 1.0)
    #expect(MotionLowPassFilter.identity.filtered(full) == full)
}

@Test func activeWindowDetectorLocatesGestureRegionInsidePadding() {
    // 构造：前后各 0.5s 静止 + 中间 0.8s burst。
    let idleBefore = (0..<25).map { i in
        MotionSample(
            timestamp: Double(i) * 0.02,
            userAcceleration: MotionVector3(x: 0.01, y: 0, z: 0),
            rotationRate: MotionVector3(x: 0, y: 0, z: 0)
        )
    }
    let burst = syntheticBurst(duration: 0.8, amplitude: 1.2).map { s in
        MotionSample(
            timestamp: s.timestamp + 0.5,
            userAcceleration: s.userAcceleration,
            rotationRate: s.rotationRate
        )
    }
    let idleAfter = (0..<25).map { i in
        MotionSample(
            timestamp: 1.3 + Double(i) * 0.02,
            userAcceleration: MotionVector3(x: 0.01, y: 0, z: 0),
            rotationRate: MotionVector3(x: 0, y: 0, z: 0)
        )
    }
    let samples = idleBefore + burst + idleAfter
    let window = MotionActiveWindowDetector().activeWindowFractions(samples)
    // 活动段应被定位在中部（不是默认 0.05/0.95）。
    #expect(window.start > 0.15)
    #expect(window.end < 0.85)
    #expect(window.end > window.start)
}

@Test func activeWindowDetectorFallsBackForFlatSignal() {
    let flat = (0..<40).map { i in
        MotionSample(
            timestamp: Double(i) * 0.02,
            userAcceleration: MotionVector3(x: 0.005, y: 0, z: 0),
            rotationRate: MotionVector3(x: 0, y: 0, z: 0)
        )
    }
    let window = MotionActiveWindowDetector().activeWindowFractions(flat)
    #expect(window.start == 0.05)
    #expect(window.end == 0.95)
}

@Test func templateFusionFlagsOutlierRecording() {
    let builder = MotionTemplateBuilder()
    // 四次一致的 burst + 一次明显不同（方向/类型不同）的录制。
    let consistent = [
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.02, phase: 0.02)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.02)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.71, amplitude: 1.01)),
    ]
    let outlier = builder.makeTemplate(label: "punch", kind: .sequence, samples: syntheticRotation(duration: 1.4, angle: .pi * 2))
    let templates = consistent + [outlier]

    let consistency = MotionTemplateFusion().consistency(of: templates)
    // 离群样本（下标 4）应被检出。
    #expect(consistency.outlierIndices.contains(4))
    // 安全阀：不会把过半样本判为离群。
    #expect(consistency.outlierIndices.count <= templates.count / 3)
}

@Test func templateFusionConsistentSetHasNoOutliersAndHighScore() {
    let builder = MotionTemplateBuilder()
    let templates = (0..<5).map { i in
        builder.makeTemplate(
            label: "punch",
            kind: .burst,
            samples: syntheticBurst(duration: 0.70 + Double(i) * 0.005, amplitude: 1.0, phase: Double(i) * 0.01)
        )
    }
    let consistency = MotionTemplateFusion().consistency(of: templates)
    #expect(consistency.outlierIndices.isEmpty)
    #expect(consistency.score > 0.5)
}

@Test func fusedPrototypeMatchesMemberGesturesCloselyAndRejectsOthers() {
    let builder = MotionTemplateBuilder()
    let matcher = MotionTemplateMatcher()
    let members = (0..<4).map { i in
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0, phase: Double(i) * 0.01))
    }
    guard let fused = MotionTemplateFusion().fusedPrototype(from: members) else {
        Issue.record("fused prototype should not be nil")
        return
    }
    let memberDistance = matcher.distance(fused.samples, syntheticBurst(duration: 0.7, amplitude: 1.0))
    let otherDistance = matcher.distance(fused.samples, syntheticRotation(duration: 1.4, angle: .pi * 2))
    #expect(memberDistance < otherDistance)
    #expect(fused.samples.count == 48)
}

@Test func collectionPlanSurfacesOutlierWarning() {
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.71, amplitude: 1.01)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.69, amplitude: 0.99)),
        builder.makeTemplate(label: "punch", kind: .sequence, samples: syntheticRotation(duration: 1.4, angle: .pi * 2)),
    ]
    let plan = GestureSampleCollectionPolicy().plan(templates: templates)
    #expect(!plan.outlierIndices.isEmpty)
    #expect(plan.warnings.contains { $0.contains("差异较大") })
    #expect(plan.consistencyScore != nil)
}

@Test func confirmationGateTriggersHighConfidenceImmediately() {
    var gate = GestureConfirmationGate(confidentMargin: 0.08, windowSeconds: 1.2)
    let id = UUID()
    // 分数明显高于阈值（margin 0.12）→ 立即触发。
    #expect(gate.register(profileID: id, score: 0.92, threshold: 0.80, at: 0.0) == .trigger)
}

@Test func confirmationGateRequiresSecondHitInGrayZone() {
    var gate = GestureConfirmationGate(confidentMargin: 0.08, windowSeconds: 1.2)
    let id = UUID()
    // 灰区（margin 0.03）→ 第一次等待。
    #expect(gate.register(profileID: id, score: 0.83, threshold: 0.80, at: 0.0) == .wait)
    // 窗口内第二次 → 确认触发。
    #expect(gate.register(profileID: id, score: 0.82, threshold: 0.80, at: 0.6) == .trigger)
    // 触发后状态清空：再次灰区命中又要等待。
    #expect(gate.register(profileID: id, score: 0.83, threshold: 0.80, at: 1.0) == .wait)
}

@Test func confirmationGateForgetsStaleGrayZoneEvidence() {
    var gate = GestureConfirmationGate(confidentMargin: 0.08, windowSeconds: 1.0)
    let id = UUID()
    #expect(gate.register(profileID: id, score: 0.83, threshold: 0.80, at: 0.0) == .wait)
    // 超过窗口（1.5 > 1.0）→ 旧证据失效，仍需等待。
    #expect(gate.register(profileID: id, score: 0.83, threshold: 0.80, at: 1.5) == .wait)
}

@Test func negativeTemplateVetoBlocksTriggerNearKnownFalseTrigger() {
    let builder = MotionTemplateBuilder()
    // 正样本：一个方向的 burst；负样本：与候选几乎相同的"误触"。
    let positives = [
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.70, amplitude: 1.0)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.02, phase: 0.02)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.02)),
    ]
    let candidate = syntheticYAxisBurst(duration: 0.71, amplitude: 1.0)
    // 负样本与候选几乎一致（已知误触）。
    let negatives = [
        builder.makeTemplate(label: "punch-neg", kind: .burst, samples: syntheticYAxisBurst(duration: 0.71, amplitude: 1.0)),
    ]
    let profile = GestureProfileBuilder().makeProfile(
        name: "punch",
        kind: .burst,
        templates: positives,
        negativeTemplates: negatives
    )
    let segment = GestureSegment(
        kind: .burst,
        samples: candidate,
        startTimestamp: 30,
        endTimestamp: 30.71,
        peakTimestamp: 30.32,
        peakEnergy: 1.0,
        features: MotionEnergyAnalyzer().features(for: candidate)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile])
    runtime.setActiveProfileIDs([profile.id])
    let evaluation = runtime.evaluate(segment: segment, now: 30.8)
    // 候选落在已知误触附近 → 不应触发。
    #expect(evaluation.candidate?.shouldTrigger != true)
}

@Test func runtimeDefaultsToInactiveSelection() {
    // 不显式传 selection 时，runtime 必须默认 .inactive（未选动作不识别）。
    let templateBuilder = MotionTemplateBuilder()
    let profile = GestureProfileBuilder().makeProfile(
        name: "punch",
        kind: .burst,
        templates: [templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0))]
    )
    let samples = syntheticBurst(duration: 0.71, amplitude: 1.02)
    let segment = GestureSegment(
        kind: .burst,
        samples: samples,
        startTimestamp: 5,
        endTimestamp: 5.71,
        peakTimestamp: 5.32,
        peakEnergy: 1.2,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    let runtime = GestureRecognitionRuntime(profiles: [profile])
    let evaluation = runtime.evaluate(segment: segment, now: 5.8)
    #expect(evaluation.candidate == nil)
    #expect(evaluation.rejectReason == .noActiveProfile)
    #expect(runtime.activeProfileIDs.isEmpty)
}

@Test func activeProfileSyncStateSupersedesByRevisionThenTimestamp() {
    let id = UUID()
    let base = Date(timeIntervalSince1970: 1_000)
    let r1 = ActiveProfileSyncState(revision: 1, profileID: id, profileName: "A", updatedAt: base, origin: "phone")
    let r2 = ActiveProfileSyncState(revision: 2, profileID: id, profileName: "A", updatedAt: base, origin: "watch")
    // 高 revision 覆盖低 revision。
    #expect(r2.supersedes(r1))
    #expect(!r1.supersedes(r2))
    // nil current 一律可覆盖。
    #expect(r1.supersedes(nil))
    // 同 revision 时按 updatedAt 决胜。
    let r2Later = ActiveProfileSyncState(revision: 2, profileID: id, profileName: "A", updatedAt: base.addingTimeInterval(5), origin: "phone")
    #expect(r2Later.supersedes(r2))
    #expect(!r2.supersedes(r2Later))
    // 严格大于：完全相同的状态不覆盖（幂等）。
    #expect(!r2.supersedes(r2))
}

@Test func activeProfileSyncStateRoundTripsThroughCodec() throws {
    let state = ActiveProfileSyncState(
        revision: 7,
        profileID: UUID(),
        profileName: "出拳",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        origin: "phone"
    )
    let data = try MotionSoundSyncCodec.encode(state)
    let decoded = try MotionSoundSyncCodec.decode(ActiveProfileSyncState.self, from: data)
    #expect(decoded == state)

    let clearState = ActiveProfileSyncState(revision: 8, profileID: nil, profileName: nil, origin: "watch")
    let clearData = try MotionSoundSyncCodec.encode(clearState)
    let clearDecoded = try MotionSoundSyncCodec.decode(ActiveProfileSyncState.self, from: clearData)
    #expect(clearDecoded.profileID == nil)
    #expect(clearDecoded.revision == 8)
}

@Test func activeProfileSyncAckRoundTripsThroughCodec() throws {
    let ack = ActiveProfileSyncAck(
        revision: 3,
        profileID: UUID(),
        profileName: "turn",
        applied: false,
        pending: true,
        reason: "libraryNotReady",
        sentAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let data = try MotionSoundSyncCodec.encode(ack)
    let decoded = try MotionSoundSyncCodec.decode(ActiveProfileSyncAck.self, from: data)
    #expect(decoded == ack)
    #expect(decoded.pending)
    #expect(!decoded.applied)
}

@Test func routedRecognitionRejectsLowScoreEvenWhenTrajectoryDistancePasses() {
    let templateBuilder = MotionTemplateBuilder()
    var profile = GestureProfileBuilder().makeProfile(
        name: "swing",
        kind: .sequence,
        templates: [
            templateBuilder.makeTemplate(label: "swing", kind: .sequence, samples: syntheticSequence(duration: 1.0, amplitude: 1.0)),
            templateBuilder.makeTemplate(label: "swing", kind: .sequence, samples: syntheticSequence(duration: 1.05, amplitude: 1.02)),
            templateBuilder.makeTemplate(label: "swing", kind: .sequence, samples: syntheticSequence(duration: 0.95, amplitude: 0.98)),
        ]
    )
    profile.acceptanceThreshold = 1.0
    var thresholds = profile.thresholds!
    thresholds.triggerScore = 0.98
    profile.thresholds = thresholds

    let samples = syntheticBurst(duration: 1.0, amplitude: 0.8)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 0,
        endTimestamp: 1,
        peakTimestamp: 0.5,
        peakEnergy: 1.0,
        features: MotionEnergyAnalyzer().features(for: samples)
    )

    let evaluation = MotionRecognitionRouter().evaluate(segment: segment, profiles: [profile])

    #expect((evaluation.candidate?.distance ?? .infinity) <= profile.acceptanceThreshold)
    #expect(evaluation.candidate?.recognitionScore != nil)
    #expect(evaluation.candidate?.shouldTrigger == false)
    #expect(evaluation.rejectReason != nil)
}

@Test func recognitionRuntimeRecordsAudioPlaybackOutcome() {
    let templateBuilder = MotionTemplateBuilder()
    let template = templateBuilder.makeTemplate(
        label: "punch",
        kind: .burst,
        samples: syntheticBurst(duration: 0.7, amplitude: 1.0)
    )
    let profile = GestureProfile(
        name: "punch",
        kind: .burst,
        templates: [template],
        acceptanceThreshold: 0.4,
        sound: SoundAsset(fileName: "punch.wav", duration: 0.4)
    )
    let samples = syntheticBurst(duration: 0.7, amplitude: 1.0)
    let segment = GestureSegment(
        kind: .burst,
        samples: samples,
        startTimestamp: 3,
        endTimestamp: 3.7,
        peakTimestamp: 3.3,
        peakEnergy: 1.0,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)
    let candidate = runtime.bestCandidate(for: segment, now: 4)

    let event = runtime.record(segment: segment, candidate: candidate, now: 4, audioPlayed: true)

    #expect(event.triggered)
    #expect(event.logEntry.audioPlayed)
    #expect(event.profile?.sound?.fileName == "punch.wav")
}

@Test func activityTrimmerFocusesLongBurstRecording() {
    var samples: [MotionSample] = []
    let interval = 0.02
    for index in 0..<120 {
        samples.append(flatSample(timestamp: Double(index) * interval, acceleration: 0.01, rotation: 0.01))
    }
    let offset = Double(samples.count) * interval
    samples.append(contentsOf: syntheticBurst(duration: 0.7, amplitude: 1.2).map {
        MotionSample(
            timestamp: $0.timestamp + offset,
            userAcceleration: $0.userAcceleration,
            rotationRate: $0.rotationRate,
            gravity: $0.gravity
        )
    })
    let tailOffset = (samples.last?.timestamp ?? offset) + interval
    for index in 0..<160 {
        samples.append(flatSample(timestamp: tailOffset + Double(index) * interval, acceleration: 0.01, rotation: 0.01))
    }

    let trimmed = MotionSampleActivityTrimmer().trimForTemplate(samples, requestedKind: .burst)
    let features = MotionEnergyAnalyzer().features(for: trimmed)

    #expect(trimmed.count < samples.count / 2)
    #expect((trimmed.last?.timestamp ?? 0) - (trimmed.first?.timestamp ?? 0) < 1.6)
    #expect(trimmed.first?.timestamp == 0)
    #expect(features.peakAcceleration > 1.0)
}

@Test func activityTrimmerKeepsSlowRotationAngleProgress() {
    var samples: [MotionSample] = []
    let interval = 0.02
    for index in 0..<60 {
        samples.append(flatSample(timestamp: Double(index) * interval, acceleration: 0.005, rotation: 0.005))
    }
    let offset = Double(samples.count) * interval
    samples.append(contentsOf: syntheticRotation(duration: 3.0, angle: .pi * 2, sampleRate: 50).map {
        MotionSample(
            timestamp: $0.timestamp + offset,
            userAcceleration: $0.userAcceleration,
            rotationRate: $0.rotationRate,
            gravity: $0.gravity
        )
    })
    let tailOffset = (samples.last?.timestamp ?? offset) + interval
    for index in 0..<70 {
        samples.append(flatSample(timestamp: tailOffset + Double(index) * interval, acceleration: 0.005, rotation: 0.005))
    }

    let trimmed = MotionSampleActivityTrimmer().trimForTemplate(
        samples,
        requestedKind: .sequence,
        strategy: .rotationAngleWindow
    )
    let duration = (trimmed.last?.timestamp ?? 0) - (trimmed.first?.timestamp ?? 0)
    let features = MotionFeatureExtractor().extract(trimmed)

    #expect(trimmed.count < samples.count)
    #expect(duration > 2.5)
    #expect(duration < 3.6)
    #expect(features.integratedRotationAngle > .pi * 1.6)
}

@Test func activityTrimmerKeepsHoldStableSuffix() {
    let samples = syntheticHoldTransition(duration: 2.2, transitionDuration: 0.7, sampleRate: 50)

    let trimmed = MotionSampleActivityTrimmer().trimForTemplate(
        samples,
        requestedKind: .posture,
        strategy: .holdStableWindow
    )
    let duration = (trimmed.last?.timestamp ?? 0) - (trimmed.first?.timestamp ?? 0)
    let features = MotionFeatureExtractor().extract(trimmed)

    #expect(trimmed.count < samples.count)
    #expect(duration > 1.2)
    #expect(duration < 1.9)
    #expect(features.holdStability > 0.70)
}

@Test func runtimeTrimsLongCandidateBeforeTrajectoryMatching() {
    let builder = MotionTemplateBuilder()
    let profile = GestureProfileBuilder().makeProfile(
        name: "punch",
        kind: .burst,
        templates: [
            builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
            builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.73, amplitude: 1.04, phase: 0.03)),
            builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.97, phase: -0.03)),
        ]
    )
    var samples: [MotionSample] = []
    let interval = 0.02
    for index in 0..<130 {
        samples.append(flatSample(timestamp: Double(index) * interval, acceleration: 0.01, rotation: 0.01))
    }
    let offset = Double(samples.count) * interval
    samples.append(contentsOf: syntheticBurst(duration: 0.72, amplitude: 1.02).map {
        MotionSample(
            timestamp: $0.timestamp + offset,
            userAcceleration: $0.userAcceleration,
            rotationRate: $0.rotationRate,
            gravity: $0.gravity,
            attitude: $0.attitude
        )
    })
    let tailOffset = (samples.last?.timestamp ?? offset) + interval
    for index in 0..<180 {
        samples.append(flatSample(timestamp: tailOffset + Double(index) * interval, acceleration: 0.01, rotation: 0.01))
    }
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: samples.first?.timestamp ?? 0,
        endTimestamp: samples.last?.timestamp ?? 0,
        peakTimestamp: offset + 0.3,
        peakEnergy: 1.2,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: samples.last?.timestamp ?? 0)

    #expect(event.triggered)
    #expect(event.profile?.id == profile.id)
    #expect(event.candidate?.distance ?? .infinity <= profile.acceptanceThreshold)
}

@Test func poseAndStageSignatureSeparateSimilarImpulseGestures() {
    let builder = MotionTemplateBuilder()
    let punchProfile = GestureProfileBuilder().makeProfile(
        name: "punch",
        kind: .burst,
        templates: [
            builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticPoseImpulse(duration: 1.0, endGravity: MotionVector3(x: 0, y: 0, z: -1), terminalHold: 0.02)),
            builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticPoseImpulse(duration: 1.04, endGravity: MotionVector3(x: 0.02, y: 0, z: -1), terminalHold: 0.02)),
            builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticPoseImpulse(duration: 0.98, endGravity: MotionVector3(x: -0.02, y: 0, z: -1), terminalHold: 0.02)),
        ]
    )
    let eyePoseProfile = GestureProfileBuilder().makeProfile(
        name: "eye-pose",
        kind: .burst,
        templates: [
            builder.makeTemplate(label: "eye-pose", kind: .burst, samples: syntheticPoseImpulse(duration: 1.25, endGravity: MotionVector3(x: 0, y: -1, z: 0), terminalHold: 0.32)),
            builder.makeTemplate(label: "eye-pose", kind: .burst, samples: syntheticPoseImpulse(duration: 1.28, endGravity: MotionVector3(x: 0.03, y: -0.99, z: 0), terminalHold: 0.34)),
            builder.makeTemplate(label: "eye-pose", kind: .burst, samples: syntheticPoseImpulse(duration: 1.22, endGravity: MotionVector3(x: -0.03, y: -0.99, z: 0), terminalHold: 0.30)),
        ]
    )
    let samples = syntheticPoseImpulse(duration: 1.02, endGravity: MotionVector3(x: 0, y: 0, z: -1), terminalHold: 0.02)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 0,
        endTimestamp: samples.last?.timestamp ?? 1,
        peakTimestamp: 0.42,
        peakEnergy: 1.0,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [eyePoseProfile, punchProfile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 1.1)

    #expect(eyePoseProfile.signature?.pose != nil)
    #expect(eyePoseProfile.signature?.stages?.contains { $0.kind == .hold } == true)
    #expect(event.triggered)
    #expect(event.profile?.id == punchProfile.id)
    #expect(event.logEntry.candidateReports.first { $0.profileID == eyePoseProfile.id }?.rejectReason != nil)
}

@Test func profileBuilderCreatesSignatureVariantsForDivergentRecordings() {
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "mixed-punch", kind: .burst, samples: syntheticBurst(duration: 0.70, amplitude: 1.0)),
        builder.makeTemplate(label: "mixed-punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.03, phase: 0.02)),
        builder.makeTemplate(label: "mixed-punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.02)),
        builder.makeTemplate(label: "mixed-punch", kind: .burst, samples: syntheticYAxisBurst(duration: 0.70, amplitude: 0.9)),
        builder.makeTemplate(label: "mixed-punch", kind: .burst, samples: syntheticYAxisBurst(duration: 0.74, amplitude: 0.92)),
    ]

    let profile = GestureProfileBuilder().makeProfile(
        name: "mixed-punch",
        kind: .burst,
        templates: templates
    )

    #expect((profile.signatureVariants?.count ?? 0) >= 2)
    #expect(profile.signatureVariants?.flatMap(\.templateIDs).count == templates.count)
    #expect(Set(profile.signatureVariants?.flatMap(\.templateIDs) ?? []) == Set(templates.map(\.id)))
}

@Test func runtimeMatchesMinorityVariantWithoutProfileAxisGate() {
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "multi-axis", kind: .burst, samples: syntheticBurst(duration: 0.70, amplitude: 1.0)),
        builder.makeTemplate(label: "multi-axis", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.02, phase: 0.02)),
        builder.makeTemplate(label: "multi-axis", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.02)),
        builder.makeTemplate(label: "multi-axis", kind: .burst, samples: syntheticYAxisBurst(duration: 0.70, amplitude: 0.9)),
        builder.makeTemplate(label: "multi-axis", kind: .burst, samples: syntheticYAxisBurst(duration: 0.74, amplitude: 0.92)),
    ]
    let profile = GestureProfileBuilder().makeProfile(
        name: "multi-axis",
        kind: .burst,
        templates: templates
    )
    let candidateSamples = syntheticYAxisBurst(duration: 0.72, amplitude: 0.91)
    let segment = GestureSegment(
        kind: .burst,
        samples: candidateSamples,
        startTimestamp: 0,
        endTimestamp: 0.72,
        peakTimestamp: 0.32,
        peakEnergy: 0.91,
        features: MotionEnergyAnalyzer().features(for: candidateSamples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 0.8)

    #expect(event.triggered)
    #expect(event.profile?.id == profile.id)
    #expect(event.candidate?.variantID != nil)
    #expect(event.logEntry.burstGateRejectionReason == nil)
}

@Test func sampleCollectionPolicyRequiresFiveSamplesBeforeSaving() {
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.02, phase: 0.02)),
    ]

    let plan = GestureSampleCollectionPolicy().plan(templates: templates)

    #expect(plan.acceptedCount == 2)
    #expect(plan.requiredCount == 5)
    #expect(plan.isReady == false)
    #expect(plan.needsMoreSamples)
}

@Test func sampleCollectionPolicyRequiresFiveEvenForConsistentSamples() {
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.72, amplitude: 1.02, phase: 0.02)),
        builder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.98, phase: -0.02)),
    ]

    let plan = GestureSampleCollectionPolicy().plan(templates: templates)

    #expect(plan.acceptedCount == 3)
    #expect(plan.requiredCount == 5)
    #expect(plan.isReady == false)
    #expect(plan.hasHighDeviation == false)
}

@Test func sampleCollectionPolicyAllowsFiveSamplesWithoutUserCorrectionFlow() {
    let builder = MotionTemplateBuilder()
    let templates = [
        builder.makeTemplate(label: "mixed", kind: .sequence, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        builder.makeTemplate(label: "mixed", kind: .sequence, samples: syntheticSequence(duration: 2.8, amplitude: 1.0)),
        builder.makeTemplate(label: "mixed", kind: .sequence, samples: syntheticSequence(duration: 0.9, amplitude: 0.35)),
        builder.makeTemplate(label: "mixed", kind: .sequence, samples: syntheticSequence(duration: 2.2, amplitude: 0.8)),
        builder.makeTemplate(label: "mixed", kind: .sequence, samples: syntheticBurst(duration: 1.1, amplitude: 0.6)),
    ]

    let plan = GestureSampleCollectionPolicy().plan(templates: templates)

    #expect(plan.acceptedCount == 5)
    #expect(plan.requiredCount == 5)
    #expect(plan.isReady)
}

@Test func singleTemplateLegacyProfileRejectsOverIntenseLooseMatch() {
    let templateBuilder = MotionTemplateBuilder()
    let template = templateBuilder.makeTemplate(
        label: "transform",
        kind: .combo,
        samples: syntheticSequence(duration: 2.1, amplitude: 1.0)
    )
    let legacyProfile = GestureProfile(
        name: "transform",
        kind: .combo,
        templates: [template],
        acceptanceThreshold: 0.6,
        cooldownSeconds: 0.3
    )
    let samples = syntheticSequence(duration: 2.1, amplitude: 2.2)
    let segment = GestureSegment(
        kind: .sequence,
        samples: samples,
        startTimestamp: 30,
        endTimestamp: 32.1,
        peakTimestamp: 31,
        peakEnergy: 2.2,
        features: MotionEnergyAnalyzer().features(for: samples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [legacyProfile], activeRecognitionSelection: .allProfiles)

    let event = runtime.recognize(segment: segment, now: 32.2, audioPlayed: true)

    #expect(event.triggered == false)
    #expect(event.profile == nil)
}

@Test func recognitionRuntimeSuppressesCooldownTrigger() {
    let templateBuilder = MotionTemplateBuilder()
    let template = templateBuilder.makeTemplate(
        label: "slash",
        kind: .sequence,
        samples: syntheticSequence(duration: 1.0, amplitude: 1.0)
    )
    let profile = GestureProfile(
        name: "slash",
        kind: .sequence,
        templates: [template],
        acceptanceThreshold: 0.4,
        cooldownSeconds: 2.0
    )
    let segment = GestureSegment(
        kind: .sequence,
        samples: syntheticSequence(duration: 1.0, amplitude: 1.0),
        startTimestamp: 20,
        endTimestamp: 21,
        peakTimestamp: 20.5,
        peakEnergy: 1.1,
        features: MotionEnergyAnalyzer().features(for: syntheticSequence(duration: 1.0, amplitude: 1.0))
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)

    let first = runtime.recognize(segment: segment, now: 21.0)
    let second = runtime.recognize(segment: segment, now: 21.5)

    #expect(first.triggered)
    #expect(second.triggered == false)
    #expect(second.candidate == nil)
    #expect(runtime.logs.count == 2)
}

@Test func feedbackEngineAddsFalseTriggerAsNegativeTemplate() {
    let templateBuilder = MotionTemplateBuilder()
    let profileBuilder = GestureProfileBuilder()
    let templates = [
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.7, amplitude: 1.0)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.73, amplitude: 1.04, phase: 0.03)),
        templateBuilder.makeTemplate(label: "punch", kind: .burst, samples: syntheticBurst(duration: 0.68, amplitude: 0.97, phase: -0.03)),
    ]
    let profile = profileBuilder.makeProfile(name: "punch", kind: .burst, templates: templates)
    let segmentSamples = syntheticBurst(duration: 0.71, amplitude: 1.02)
    let segment = GestureSegment(
        kind: .burst,
        samples: segmentSamples,
        startTimestamp: 10,
        endTimestamp: 10.71,
        peakTimestamp: 10.32,
        peakEnergy: 1.2,
        features: MotionEnergyAnalyzer().features(for: segmentSamples)
    )
    var runtime = GestureRecognitionRuntime(profiles: [profile], activeRecognitionSelection: .allProfiles)
    let event = runtime.recognize(segment: segment, now: 11)

    let updatedProfiles = GestureFeedbackEngine().applyFalseTrigger(event: event, to: [profile])

    #expect(event.triggered)
    #expect(updatedProfiles.count == 1)
    #expect(updatedProfiles[0].id == profile.id)
    #expect(updatedProfiles[0].negativeTemplates.count == 1)
    #expect(updatedProfiles[0].strictness > profile.strictness)
    #expect(updatedProfiles[0].updatedAt >= profile.updatedAt)
}

private func syntheticBurst(
    duration: Double,
    amplitude: Double,
    phase: Double = 0,
    sampleRate: Double = 50
) -> [MotionSample] {
    let count = max(12, Int(duration * sampleRate))
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let pulse = amplitude * exp(-pow((progress - 0.42 - phase) * 7, 2))
        return MotionSample(
            timestamp: progress * duration,
            userAcceleration: MotionVector3(x: pulse, y: pulse * 0.35, z: -pulse * 0.15),
            rotationRate: MotionVector3(x: pulse * 0.1, y: pulse * 0.55, z: pulse * 0.25)
        )
    }
}

private func syntheticYAxisBurst(
    duration: Double,
    amplitude: Double,
    sampleRate: Double = 50
) -> [MotionSample] {
    let count = max(12, Int(duration * sampleRate))
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let pulse = amplitude * exp(-pow((progress - 0.42) * 7, 2))
        return MotionSample(
            timestamp: progress * duration,
            userAcceleration: MotionVector3(x: pulse * 0.2, y: pulse, z: -pulse * 0.1),
            rotationRate: MotionVector3(x: pulse * 0.1, y: pulse * 0.45, z: pulse * 0.2)
        )
    }
}

private func syntheticPoseImpulse(
    duration: Double,
    endGravity: MotionVector3,
    terminalHold: Double,
    amplitude: Double = 1.0,
    sampleRate: Double = 50
) -> [MotionSample] {
    let count = max(16, Int(duration * sampleRate))
    let movementDuration = max(0.25, duration - terminalHold)
    let startGravity = MotionVector3(x: 0, y: 0, z: -1)
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let timestamp = progress * duration
        let movementProgress = min(1, timestamp / movementDuration)
        let pulse = timestamp <= movementDuration
            ? amplitude * exp(-pow((movementProgress - 0.42) * 7, 2))
            : 0
        return MotionSample(
            timestamp: timestamp,
            userAcceleration: MotionVector3(x: pulse, y: pulse * 0.34, z: -pulse * 0.12),
            rotationRate: MotionVector3(x: pulse * 0.12, y: pulse * 0.52, z: pulse * 0.22),
            gravity: MotionVector3(
                x: startGravity.x + (endGravity.x - startGravity.x) * movementProgress,
                y: startGravity.y + (endGravity.y - startGravity.y) * movementProgress,
                z: startGravity.z + (endGravity.z - startGravity.z) * movementProgress
            )
        )
    }
}

private func flatSample(timestamp: Double, acceleration: Double = 0, rotation: Double = 0) -> MotionSample {
    MotionSample(
        timestamp: timestamp,
        userAcceleration: MotionVector3(x: acceleration, y: 0, z: 0),
        rotationRate: MotionVector3(x: 0, y: rotation, z: 0)
    )
}

private func burstStream() -> [MotionSample] {
    var output: [MotionSample] = []
    let interval = 0.02

    for index in 0..<15 {
        output.append(flatSample(timestamp: Double(index) * interval, acceleration: 0.02))
    }

    for index in 15..<33 {
        let progress = Double(index - 15) / 17
        let pulse = 1.0 * exp(-pow((progress - 0.45) * 4, 2))
        output.append(flatSample(timestamp: Double(index) * interval, acceleration: max(0.25, pulse), rotation: pulse * 0.7))
    }

    for index in 33..<55 {
        output.append(flatSample(timestamp: Double(index) * interval, acceleration: 0.02))
    }

    return output
}

private func syntheticSequence(
    duration: Double,
    amplitude: Double,
    sampleRate: Double = 50
) -> [MotionSample] {
    let count = max(12, Int(duration * sampleRate))
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let angle = progress * Double.pi * 2
        return MotionSample(
            timestamp: progress * duration,
            userAcceleration: MotionVector3(
                x: amplitude * sin(angle),
                y: amplitude * cos(angle * 0.6),
                z: amplitude * sin(angle * 1.4) * 0.4
            ),
            rotationRate: MotionVector3(
                x: amplitude * cos(angle) * 0.45,
                y: amplitude * sin(angle * 0.5) * 0.8,
                z: amplitude * cos(angle * 1.2) * 0.35
            )
        )
    }
}

private func syntheticRotation(
    duration: Double,
    angle: Double,
    sampleRate: Double = 50,
    axis: Int = 2
) -> [MotionSample] {
    let count = max(12, Int(duration * sampleRate))
    let angularVelocity = angle / duration
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let timestamp = progress * duration
        let wobble = 0.03 * sin(progress * .pi * 4)
        let rotation: MotionVector3
        switch axis {
        case 0:
            rotation = MotionVector3(x: angularVelocity, y: wobble, z: wobble * 0.5)
        case 1:
            rotation = MotionVector3(x: wobble, y: angularVelocity, z: wobble * 0.5)
        default:
            rotation = MotionVector3(x: wobble, y: wobble * 0.5, z: angularVelocity)
        }
        return MotionSample(
            timestamp: timestamp,
            userAcceleration: MotionVector3(x: wobble * 0.2, y: wobble * 0.1, z: 0.02 * cos(progress * .pi * 2)),
            rotationRate: rotation
        )
    }
}

private func syntheticDiagonalRotation(
    duration: Double,
    angle: Double,
    sampleRate: Double = 50
) -> [MotionSample] {
    let count = max(12, Int(duration * sampleRate))
    let angularVelocity = angle / duration
    let axisScale = 1.0 / sqrt(2.0)
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let timestamp = progress * duration
        let wobble = 0.015 * sin(progress * .pi * 4)
        return MotionSample(
            timestamp: timestamp,
            userAcceleration: MotionVector3(x: wobble, y: wobble * 0.5, z: wobble),
            rotationRate: MotionVector3(
                x: angularVelocity * axisScale,
                y: wobble,
                z: angularVelocity * axisScale
            )
        )
    }
}

private func syntheticHoldTransition(
    duration: Double,
    transitionDuration: Double,
    sampleRate: Double = 50
) -> [MotionSample] {
    let count = max(12, Int(duration * sampleRate))
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let timestamp = progress * duration
        let movementProgress = min(1, timestamp / transitionDuration)
        let pulse = timestamp <= transitionDuration
            ? exp(-pow((movementProgress - 0.45) * 5, 2))
            : 0
        return MotionSample(
            timestamp: timestamp,
            userAcceleration: MotionVector3(x: pulse * 0.35, y: pulse * 0.12, z: 0.02),
            rotationRate: MotionVector3(x: pulse * 0.18, y: pulse * 0.12, z: pulse * 0.08),
            gravity: MotionVector3(
                x: 0.2 * movementProgress,
                y: 0.4 * movementProgress,
                z: -1 + 0.08 * movementProgress
            )
        )
    }
}

private func syntheticOscillatingRotation(
    duration: Double,
    angle: Double,
    sampleRate: Double = 50,
    axis: Int = 2
) -> [MotionSample] {
    let count = max(12, Int(duration * sampleRate))
    let interval = duration / Double(count - 1)
    let baseVelocity = angle / duration
    return (0..<count).map { index in
        let progress = Double(index) / Double(count - 1)
        let timestamp = Double(index) * interval
        let sign = sin(progress * .pi * 4) >= 0 ? 1.0 : -1.0
        let velocity = baseVelocity * sign
        let wobble = 0.02 * cos(progress * .pi * 6)
        let rotation: MotionVector3
        switch axis {
        case 0:
            rotation = MotionVector3(x: velocity, y: wobble, z: wobble * 0.5)
        case 1:
            rotation = MotionVector3(x: wobble, y: velocity, z: wobble * 0.5)
        default:
            rotation = MotionVector3(x: wobble, y: wobble * 0.5, z: velocity)
        }
        return MotionSample(
            timestamp: timestamp,
            userAcceleration: MotionVector3(x: wobble * 0.2, y: wobble * 0.1, z: 0.03 * sin(progress * .pi * 2)),
            rotationRate: rotation
        )
    }
}
