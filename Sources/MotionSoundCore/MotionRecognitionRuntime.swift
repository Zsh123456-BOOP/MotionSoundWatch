import Foundation

public struct GestureRecognitionEvent: Equatable, Sendable {
    public var segment: GestureSegment
    public var candidate: RecognitionCandidate?
    public var logEntry: RecognitionLogEntry

    public var triggered: Bool {
        logEntry.triggered
    }

    public var profile: GestureProfile? {
        candidate?.profile
    }

    public init(segment: GestureSegment, candidate: RecognitionCandidate?, logEntry: RecognitionLogEntry) {
        self.segment = segment
        self.candidate = candidate
        self.logEntry = logEntry
    }
}

public struct RecognitionEvaluation: Equatable, Sendable {
    public var candidate: RecognitionCandidate?
    public var burstGateRejectionReason: BurstGateRejectionReason?
    public var tokens: [MotionToken]
    public var classifiedKind: MotionTokenKind?
    public var candidateReports: [CandidateRecognitionReport]
    public var rejectReason: RejectReason?

    public init(
        candidate: RecognitionCandidate?,
        burstGateRejectionReason: BurstGateRejectionReason? = nil,
        tokens: [MotionToken] = [],
        classifiedKind: MotionTokenKind? = nil,
        candidateReports: [CandidateRecognitionReport] = [],
        rejectReason: RejectReason? = nil
    ) {
        self.candidate = candidate
        self.burstGateRejectionReason = burstGateRejectionReason
        self.tokens = tokens
        self.classifiedKind = classifiedKind
        self.candidateReports = candidateReports
        self.rejectReason = rejectReason
    }
}

public struct ContinuousRecognitionEvaluation: Equatable, Sendable {
    public var segment: GestureSegment
    public var evaluation: RecognitionEvaluation

    public init(segment: GestureSegment, evaluation: RecognitionEvaluation) {
        self.segment = segment
        self.evaluation = evaluation
    }
}

public struct GestureRecognitionRuntime: Sendable {
    public var profiles: [GestureProfile]
    public var matcher: MotionTemplateMatcher
    public var segmenter: MotionGestureSegmenter
    public var burstGate: MotionBurstGate
    public var router: MotionRecognitionRouter
    public var continuousEvaluationInterval: Double
    public private(set) var activeRecognitionSelection: ActiveRecognitionSelection
    public private(set) var lastTriggerTimes: [UUID: Double]
    public private(set) var logs: [RecognitionLogEntry]
    private var continuousBuffer: MotionRingBuffer
    private var lastContinuousEvaluationAt: Double

    public init(
        profiles: [GestureProfile] = [],
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        segmenter: MotionGestureSegmenter = MotionGestureSegmenter(),
        burstGate: MotionBurstGate = MotionBurstGate(),
        router: MotionRecognitionRouter = MotionRecognitionRouter(),
        continuousEvaluationInterval: Double = 0.18,
        activeRecognitionSelection: ActiveRecognitionSelection? = nil
    ) {
        self.profiles = profiles
        self.matcher = matcher
        self.segmenter = segmenter
        self.burstGate = burstGate
        self.router = router
        self.continuousEvaluationInterval = continuousEvaluationInterval
        self.activeRecognitionSelection = activeRecognitionSelection
            ?? ActiveRecognitionSelection(mode: .allProfiles, activeProfileIDs: Set(profiles.map(\.id)))
        self.lastTriggerTimes = [:]
        self.logs = []
        self.continuousBuffer = MotionRingBuffer(maxDuration: 10)
        self.lastContinuousEvaluationAt = -.infinity
    }

    public mutating func replaceProfiles(_ profiles: [GestureProfile]) {
        self.profiles = profiles.map(runtimeAdjustedProfile)
        lastTriggerTimes = lastTriggerTimes.filter { id, _ in
            profiles.contains { $0.id == id }
        }
        activeRecognitionSelection.activeProfileIDs = activeRecognitionSelection.activeProfileIDs.filter { id in
            profiles.contains { $0.id == id }
        }
    }

    public var activeProfileIDs: Set<UUID> {
        activeRecognitionSelection.activeProfileIDs
    }

    public var activeProfiles: [GestureProfile] {
        profilesForRecognition()
    }

    public mutating func setActiveProfileIDs(_ profileIDs: Set<UUID>) {
        setActiveRecognitionSelection(ActiveRecognitionSelection(mode: .activeProfiles, activeProfileIDs: profileIDs))
    }

    public mutating func setActiveRecognitionSelection(_ selection: ActiveRecognitionSelection) {
        let validIDs = Set(profiles.map(\.id))
        var next = selection
        next.activeProfileIDs = next.activeProfileIDs.intersection(validIDs)
        guard next != activeRecognitionSelection else { return }
        activeRecognitionSelection = next
        continuousBuffer.removeAll()
        lastContinuousEvaluationAt = -.infinity
    }

    private func profilesForRecognition() -> [GestureProfile] {
        switch activeRecognitionSelection.mode {
        case .allProfiles:
            return profiles
        case .activeProfiles:
            guard !activeRecognitionSelection.activeProfileIDs.isEmpty else { return [] }
            return profiles.filter { activeRecognitionSelection.activeProfileIDs.contains($0.id) }
        }
    }

    private var shouldRejectForMissingActiveProfile: Bool {
        activeRecognitionSelection.mode == .activeProfiles && profilesForRecognition().isEmpty
    }

    private func runtimeAdjustedProfile(_ profile: GestureProfile) -> GestureProfile {
        guard profile.signature != nil else {
            return profile
        }

        var adjusted = profile
        var thresholds = adjusted.thresholds ?? ThresholdProfile()
        let isSingleTemplate = adjusted.templates.count <= 1
        let minimumTriggerScore: Double
        let minimumMarginScore: Double

        switch adjusted.signature?.primaryKind {
        case .impulse:
            minimumTriggerScore = isSingleTemplate ? 0.80 : 0.72
            minimumMarginScore = isSingleTemplate ? 0.14 : 0.08
        case .rotation:
            minimumTriggerScore = isSingleTemplate ? 0.78 : 0.64
            minimumMarginScore = isSingleTemplate ? 0.16 : 0.06
        case .oscillation:
            minimumTriggerScore = isSingleTemplate ? 0.76 : 0.60
            minimumMarginScore = isSingleTemplate ? 0.14 : 0.06
        case .hold:
            minimumTriggerScore = isSingleTemplate ? 0.80 : 0.72
            minimumMarginScore = isSingleTemplate ? 0.12 : 0.08
        case .sweep:
            minimumTriggerScore = isSingleTemplate ? 0.78 : 0.70
            minimumMarginScore = isSingleTemplate ? 0.14 : 0.08
        case .pause:
            minimumTriggerScore = 0.84
            minimumMarginScore = 0.16
        case .free, nil:
            minimumTriggerScore = isSingleTemplate ? 0.82 : 0.74
            minimumMarginScore = isSingleTemplate ? 0.16 : 0.10
        }

        thresholds.triggerScore = max(thresholds.triggerScore, minimumTriggerScore)
        thresholds.marginScore = max(thresholds.marginScore, minimumMarginScore)
        adjusted.thresholds = thresholds
        adjusted.marginThreshold = max(adjusted.marginThreshold, isSingleTemplate ? 0.08 : 0.05)
        adjusted.cooldownSeconds = max(adjusted.cooldownSeconds, isSingleTemplate ? 1.4 : 1.0)
        if var policy = adjusted.triggerPolicy {
            policy.cooldownSeconds = max(policy.cooldownSeconds, adjusted.cooldownSeconds)
            adjusted.triggerPolicy = policy
        }
        if var variants = adjusted.signatureVariants {
            variants = variants.map { variant in
                var adjustedVariant = variant
                var thresholds = variant.thresholds
                let isSingleTemplate = variant.templateIDs.count <= 1
                let minimumTriggerScore: Double
                let minimumMarginScore: Double
                switch variant.signature.primaryKind {
                case .impulse:
                    minimumTriggerScore = isSingleTemplate ? 0.80 : 0.72
                    minimumMarginScore = isSingleTemplate ? 0.14 : 0.08
                case .rotation:
                    minimumTriggerScore = isSingleTemplate ? 0.78 : 0.64
                    minimumMarginScore = isSingleTemplate ? 0.16 : 0.06
                case .oscillation:
                    minimumTriggerScore = isSingleTemplate ? 0.76 : 0.60
                    minimumMarginScore = isSingleTemplate ? 0.14 : 0.06
                case .hold:
                    minimumTriggerScore = isSingleTemplate ? 0.80 : 0.72
                    minimumMarginScore = isSingleTemplate ? 0.12 : 0.08
                case .sweep:
                    minimumTriggerScore = isSingleTemplate ? 0.78 : 0.70
                    minimumMarginScore = isSingleTemplate ? 0.14 : 0.08
                case .pause:
                    minimumTriggerScore = 0.84
                    minimumMarginScore = 0.16
                case .free:
                    minimumTriggerScore = isSingleTemplate ? 0.82 : 0.74
                    minimumMarginScore = isSingleTemplate ? 0.16 : 0.10
                }
                thresholds.triggerScore = max(thresholds.triggerScore, minimumTriggerScore)
                thresholds.marginScore = max(thresholds.marginScore, minimumMarginScore)
                adjustedVariant.thresholds = thresholds
                adjustedVariant.marginThreshold = max(adjustedVariant.marginThreshold, isSingleTemplate ? 0.08 : 0.05)
                return adjustedVariant
            }
            adjusted.signatureVariants = variants
        }
        return adjusted
    }

    public mutating func ingest(
        _ sample: MotionSample,
        batteryLevel: Double? = nil,
        wearContext: WearContext? = nil,
        audioPlayed: Bool = false
    ) -> GestureRecognitionEvent? {
        continuousBuffer.append(sample)
        guard let segment = segmenter.ingest(sample) else {
            return nil
        }

        return recognize(
            segment: segment,
            now: sample.timestamp,
            batteryLevel: batteryLevel,
            wearContext: wearContext,
            audioPlayed: audioPlayed
        )
    }

    public mutating func recognize(
        segment: GestureSegment,
        now: Double? = nil,
        batteryLevel: Double? = nil,
        wearContext: WearContext? = nil,
        audioPlayed: Bool = false
    ) -> GestureRecognitionEvent {
        let evaluation = evaluate(segment: segment, now: now)
        return record(
            segment: segment,
            candidate: evaluation.candidate,
            now: now,
            batteryLevel: batteryLevel,
            wearContext: wearContext,
            audioPlayed: audioPlayed,
            burstGateRejectionReason: evaluation.burstGateRejectionReason,
            tokens: evaluation.tokens,
            classifiedKind: evaluation.classifiedKind,
            candidateReports: evaluation.candidateReports,
            rejectReason: evaluation.rejectReason
        )
    }

    public func bestCandidate(for segment: GestureSegment, now: Double? = nil) -> RecognitionCandidate? {
        evaluate(segment: segment, now: now).candidate
    }

    public mutating func evaluateContinuous(
        sample: MotionSample,
        now: Double? = nil
    ) -> ContinuousRecognitionEvaluation? {
        continuousBuffer.append(sample)
        let timestamp = now ?? sample.timestamp
        guard timestamp - lastContinuousEvaluationAt >= continuousEvaluationInterval else {
            return nil
        }
        lastContinuousEvaluationAt = timestamp

        let recognitionProfiles = profilesForRecognition()
        let eligible = recognitionProfiles.filter(isContinuousEpisodeProfile)
        guard !eligible.isEmpty else { return nil }
        let candidateDurations = continuousCandidateDurations(from: eligible)

        var best: ContinuousRecognitionEvaluation?
        var bestScore = 0.0
        for duration in candidateDurations {
            let samples = continuousBuffer.recent(seconds: duration, endingAt: sample.timestamp)
            guard samples.count >= 12,
                  let segment = makeContinuousSegment(samples: samples) else {
                continue
            }
            let evaluation = evaluate(segment: segment, now: timestamp)
            guard let candidate = evaluation.candidate,
                  isContinuousEpisodeProfile(candidate.profile) else {
                continue
            }
            let score = candidate.recognitionScore ?? candidate.confidence
            if best == nil || score > bestScore {
                bestScore = score
                best = ContinuousRecognitionEvaluation(segment: segment, evaluation: evaluation)
            }
        }

        guard let best,
              best.evaluation.candidate?.shouldTrigger == true else {
            return nil
        }
        continuousBuffer.removeAll(keepingCapacity: true)
        lastContinuousEvaluationAt = timestamp
        return best
    }

    public func evaluate(segment: GestureSegment, now: Double? = nil) -> RecognitionEvaluation {
        guard !shouldRejectForMissingActiveProfile else {
            return RecognitionEvaluation(candidate: nil, rejectReason: .noActiveProfile)
        }
        return completedCandidateSegments(for: segment)
            .map { evaluateSingle(segment: $0, now: now) }
            .max { evaluationPriority($0) < evaluationPriority($1) }
            ?? evaluateSingle(segment: segment, now: now)
    }

    private func evaluateSingle(segment: GestureSegment, now: Double? = nil) -> RecognitionEvaluation {
        let routed = router.evaluate(
            segment: segment,
            profiles: profilesForRecognition(),
            lastTriggerTimes: lastTriggerTimes,
            now: now,
            burstGate: burstGate
        )
        var acceptedCandidate = routed.candidate.flatMap { candidate in
            strictCandidateGateAllows(candidate, for: segment) ? candidate : nil
        }
        let strictRejectReason: RejectReason? = routed.candidate != nil && acceptedCandidate == nil
            ? .scoreBelowThreshold
            : routed.rejectReason

        if let candidate = acceptedCandidate, !candidate.shouldTrigger {
            acceptedCandidate = candidate
        }
        return RecognitionEvaluation(
            candidate: acceptedCandidate,
            burstGateRejectionReason: acceptedCandidate?.shouldTrigger == true ? nil : routed.burstGateRejectionReason,
            tokens: routed.tokens,
            classifiedKind: routed.classifiedKind,
            candidateReports: routed.candidateReports,
            rejectReason: acceptedCandidate?.shouldTrigger == true ? nil : strictRejectReason
        )
    }

    private func evaluationPriority(_ evaluation: RecognitionEvaluation) -> Double {
        guard let candidate = evaluation.candidate else {
            return -1
        }
        let score = candidate.recognitionScore ?? candidate.confidence
        return candidate.shouldTrigger ? score + 1 : score
    }

    private func isContinuousEpisodeProfile(_ profile: GestureProfile) -> Bool {
        guard let signature = profile.signature else { return false }
        switch signature.primaryKind {
        case .rotation, .oscillation, .hold:
            return true
        case .free:
            return signature.rotation != nil || signature.oscillation != nil || signature.hold != nil
        case .impulse, .sweep, .pause:
            return false
        }
    }

    private func continuousDurations(for profile: GestureProfile) -> [Double] {
        let expected = max(0.45, averageTemplateDuration(profile))
        var durations: Set<Int> = []
        let multipliers: [Double]
        switch profile.signature?.primaryKind {
        case .rotation:
            multipliers = [0.55, 0.72, 1.0, 1.35, 1.80]
        case .oscillation:
            multipliers = [0.50, 0.72, 1.0, 1.25]
        case .hold:
            multipliers = [0.65, 1.0, 1.25]
        default:
            multipliers = [0.72, 1.0, 1.35]
        }
        for multiplier in multipliers {
            let duration = max(0.45, min(8.0, expected * multiplier))
            durations.insert(Int((duration * 100).rounded()))
        }
        if let minAngle = profile.thresholds?.minAngle,
           let rotation = profile.signature?.rotation,
           rotation.totalAngleRadians > 0 {
            let ratio = max(0.35, min(1.0, minAngle / rotation.totalAngleRadians))
            durations.insert(Int((max(0.45, min(8.0, expected * ratio)) * 100).rounded()))
        }
        if let minHold = profile.thresholds?.minHoldDuration {
            durations.insert(Int((max(0.45, min(8.0, minHold * 1.05)) * 100).rounded()))
        }
        return durations
            .map { Double($0) / 100.0 }
            .sorted()
    }

    private func continuousCandidateDurations(from profiles: [GestureProfile]) -> [Double] {
        var durations = Set<Int>()
        for profile in profiles {
            for duration in continuousDurations(for: profile) {
                durations.insert(Int((duration * 100).rounded()))
            }
        }
        return durations
            .map { Double($0) / 100.0 }
            .sorted()
    }

    private func completedCandidateSegments(for segment: GestureSegment) -> [GestureSegment] {
        var segments = [segment]
        let endingAt = segment.endTimestamp
        var durations = Set<Int>()

        for profile in profilesForRecognition() {
            let expected = max(0.35, averageTemplateDuration(profile))
            for multiplier in [0.85, 1.0, 1.18, 1.35] {
                let duration = max(segment.duration, min(8.0, expected * multiplier))
                guard duration > segment.duration + 0.08 else { continue }
                durations.insert(Int((duration * 100).rounded()))
            }
        }

        for durationKey in durations.sorted() {
            let duration = Double(durationKey) / 100.0
            let samples = continuousBuffer.recent(seconds: duration, endingAt: endingAt)
            guard samples.count >= 12,
                  let first = samples.first,
                  first.timestamp < segment.startTimestamp - 0.04,
                  let completed = makeContinuousSegment(samples: samples) else {
                continue
            }
            segments.append(completed)
        }

        return segments
    }

    private func averageTemplateDuration(_ profile: GestureProfile) -> Double {
        let durations = profile.templates.map(\.rawDuration).filter { $0 > 0 }
        guard !durations.isEmpty else {
            return profile.signature?.rotation?.duration
                ?? profile.signature?.oscillation?.duration
                ?? profile.signature?.hold?.duration
                ?? 1.2
        }
        return durations.reduce(0, +) / Double(durations.count)
    }

    private func makeContinuousSegment(samples: [MotionSample]) -> GestureSegment? {
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else {
            return nil
        }
        let features = MotionEnergyAnalyzer().features(for: samples)
        let frames = MotionEnergyAnalyzer().frames(for: samples)
        let peakFrame = frames.max { $0.energy < $1.energy }
        let duration = max(0, last.timestamp - first.timestamp)
        let kind: GestureKind = duration <= 0.8 ? .burst : .sequence
        return GestureSegment(
            kind: kind,
            samples: samples,
            startTimestamp: first.timestamp,
            endTimestamp: last.timestamp,
            peakTimestamp: peakFrame?.timestamp ?? last.timestamp,
            peakEnergy: peakFrame?.energy ?? 0,
            features: features
        )
    }

    public func eligibleProfiles(for segment: GestureSegment) -> [GestureProfile] {
        let matchingProfiles = profilesForRecognition().filter { $0.kind == segment.kind || $0.kind == .combo }
        return matchingProfiles.filter { burstGate.decision(for: segment, profile: $0).isAllowed }
    }

    public func burstGateDecision(for segment: GestureSegment, profile: GestureProfile) -> BurstGateDecision {
        burstGate.decision(for: segment, profile: profile)
    }

    private func strictCandidateGateAllows(_ candidate: RecognitionCandidate, for segment: GestureSegment) -> Bool {
        guard candidate.shouldTrigger else {
            return true
        }

        let profile = candidate.profile
        guard profile.signature == nil else {
            return true
        }
        guard profile.templates.count <= 1, profile.negativeTemplates.isEmpty else {
            return true
        }

        guard let template = profile.templates.first(where: { $0.id == candidate.templateID })
            ?? profile.templates.first else {
            return false
        }

        let strictThreshold = singleTemplateRuntimeThreshold(for: profile.kind)
        guard candidate.distance <= min(profile.acceptanceThreshold, strictThreshold) else {
            return false
        }

        guard durationLooksLikeTemplate(segment.duration, templateDuration: template.rawDuration, kind: profile.kind) else {
            return false
        }

        guard intensityLooksLikeTemplate(segment.features, templateFeatures: template.features, kind: profile.kind) else {
            return false
        }

        return true
    }

    private func singleTemplateRuntimeThreshold(for kind: GestureKind) -> Double {
        switch kind {
        case .burst:
            return 0.30
        case .sequence, .combo:
            return 0.20
        case .posture:
            return 0.16
        }
    }

    private func durationLooksLikeTemplate(_ duration: Double, templateDuration: Double, kind: GestureKind) -> Bool {
        guard duration > 0, templateDuration > 0 else { return false }
        let ratio = duration / templateDuration
        switch kind {
        case .burst:
            return ratio >= 0.55 && ratio <= 1.55
        case .sequence, .combo:
            return ratio >= 0.70 && ratio <= 1.30
        case .posture:
            return ratio >= 0.85 && ratio <= 1.25
        }
    }

    private func intensityLooksLikeTemplate(
        _ features: GestureFeatures,
        templateFeatures: GestureFeatures?,
        kind: GestureKind
    ) -> Bool {
        guard let templateFeatures else { return false }
        if features.dominantAxis != templateFeatures.dominantAxis,
           features.peakAcceleration < 2.2 {
            return false
        }

        let peakAccelerationRatio = safeRatio(features.peakAcceleration, templateFeatures.peakAcceleration)
        let peakRotationRatio = safeRatio(features.peakRotationRate, templateFeatures.peakRotationRate)

        switch kind {
        case .burst:
            return peakAccelerationRatio >= 0.45 && peakAccelerationRatio <= 2.25
                && peakRotationRatio <= 2.6
        case .sequence, .combo:
            return peakAccelerationRatio >= 0.55 && peakAccelerationRatio <= 1.85
                && peakRotationRatio <= 2.05
        case .posture:
            return peakAccelerationRatio <= 1.35 && peakRotationRatio <= 1.35
        }
    }

    private func safeRatio(_ value: Double, _ reference: Double) -> Double {
        guard reference > 0.0001 else {
            return value > 0.0001 ? .infinity : 1
        }
        return value / reference
    }

    public mutating func record(
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        now: Double? = nil,
        batteryLevel: Double? = nil,
        wearContext: WearContext? = nil,
        audioPlayed: Bool = false,
        burstGateRejectionReason: BurstGateRejectionReason? = nil,
        tokens: [MotionToken] = [],
        classifiedKind: MotionTokenKind? = nil,
        candidateReports: [CandidateRecognitionReport] = [],
        rejectReason: RejectReason? = nil
    ) -> GestureRecognitionEvent {
        let shouldTrigger = candidate?.shouldTrigger == true

        if shouldTrigger, let profileID = candidate?.profile.id {
            lastTriggerTimes[profileID] = now ?? segment.endTimestamp
        }

        let logEntry = makeLogEntry(
            segment: segment,
            candidate: candidate,
            triggered: shouldTrigger,
            audioPlayed: shouldTrigger && audioPlayed,
            batteryLevel: batteryLevel,
            wearContext: wearContext,
            burstGateRejectionReason: burstGateRejectionReason,
            tokens: tokens,
            classifiedKind: classifiedKind,
            candidateReports: candidateReports,
            rejectReason: rejectReason
        )
        logs.append(logEntry)

        return GestureRecognitionEvent(segment: segment, candidate: candidate, logEntry: logEntry)
    }

    public mutating func resetLogs(keepingCapacity: Bool = false) {
        logs.removeAll(keepingCapacity: keepingCapacity)
    }

    public mutating func markTriggered(profileID: UUID, at timestamp: Double) {
        lastTriggerTimes[profileID] = timestamp
    }

    public mutating func resetRuntimeState() {
        segmenter.reset()
        continuousBuffer.removeAll()
        lastContinuousEvaluationAt = -.infinity
        lastTriggerTimes.removeAll()
        resetLogs()
    }

    private func makeLogEntry(
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        triggered: Bool,
        audioPlayed: Bool,
        batteryLevel: Double?,
        wearContext: WearContext?,
        burstGateRejectionReason: BurstGateRejectionReason?,
        tokens: [MotionToken],
        classifiedKind: MotionTokenKind?,
        candidateReports: [CandidateRecognitionReport],
        rejectReason: RejectReason?
    ) -> RecognitionLogEntry {
        RecognitionLogEntry(
            timestamp: segment.endTimestamp,
            gestureKindDetected: segment.kind,
            duration: segment.duration,
            peakAcceleration: segment.features.peakAcceleration,
            peakRotationRate: segment.features.peakRotationRate,
            bestProfileID: candidate?.profile.id,
            bestDistance: candidate?.distance,
            secondBestDistance: candidate?.secondBestDistance,
            threshold: candidate?.profile.acceptanceThreshold,
            margin: candidate?.margin,
            triggered: triggered,
            audioPlayed: audioPlayed,
            batteryLevel: batteryLevel,
            wearContext: wearContext,
            burstGateRejectionReason: burstGateRejectionReason,
            tokens: tokens,
            classifiedKind: classifiedKind,
            candidateReports: candidateReports,
            rejectReason: rejectReason
        )
    }
}

public struct RecognitionLogArchive: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var logs: [RecognitionLogEntry]
    public var exportedAt: Date

    public init(schemaVersion: Int = 1, logs: [RecognitionLogEntry], exportedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.logs = logs
        self.exportedAt = exportedAt
    }
}
