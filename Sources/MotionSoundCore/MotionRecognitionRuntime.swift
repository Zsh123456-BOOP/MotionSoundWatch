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

public struct GestureRecognitionRuntime: Sendable {
    public var profiles: [GestureProfile]
    public var matcher: MotionTemplateMatcher
    public var segmenter: MotionGestureSegmenter
    public var burstGate: MotionBurstGate
    public var router: MotionRecognitionRouter
    public private(set) var lastTriggerTimes: [UUID: Double]
    public private(set) var logs: [RecognitionLogEntry]

    public init(
        profiles: [GestureProfile] = [],
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        segmenter: MotionGestureSegmenter = MotionGestureSegmenter(),
        burstGate: MotionBurstGate = MotionBurstGate(),
        router: MotionRecognitionRouter = MotionRecognitionRouter()
    ) {
        self.profiles = profiles
        self.matcher = matcher
        self.segmenter = segmenter
        self.burstGate = burstGate
        self.router = router
        self.lastTriggerTimes = [:]
        self.logs = []
    }

    public mutating func replaceProfiles(_ profiles: [GestureProfile]) {
        self.profiles = profiles
        lastTriggerTimes = lastTriggerTimes.filter { id, _ in
            profiles.contains { $0.id == id }
        }
    }

    public mutating func ingest(
        _ sample: MotionSample,
        batteryLevel: Double? = nil,
        wearContext: WearContext? = nil,
        audioPlayed: Bool = false
    ) -> GestureRecognitionEvent? {
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

    public func evaluate(segment: GestureSegment, now: Double? = nil) -> RecognitionEvaluation {
        let routed = router.evaluate(
            segment: segment,
            profiles: profiles,
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

    public func eligibleProfiles(for segment: GestureSegment) -> [GestureProfile] {
        let matchingProfiles = profiles.filter { $0.kind == segment.kind || $0.kind == .combo }
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

    public mutating func resetRuntimeState() {
        segmenter.reset()
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
