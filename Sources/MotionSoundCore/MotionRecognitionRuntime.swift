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

    public init(
        candidate: RecognitionCandidate?,
        burstGateRejectionReason: BurstGateRejectionReason? = nil
    ) {
        self.candidate = candidate
        self.burstGateRejectionReason = burstGateRejectionReason
    }
}

public struct GestureRecognitionRuntime: Sendable {
    public var profiles: [GestureProfile]
    public var matcher: MotionTemplateMatcher
    public var segmenter: MotionGestureSegmenter
    public var burstGate: MotionBurstGate
    public private(set) var lastTriggerTimes: [UUID: Double]
    public private(set) var logs: [RecognitionLogEntry]

    public init(
        profiles: [GestureProfile] = [],
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        segmenter: MotionGestureSegmenter = MotionGestureSegmenter(),
        burstGate: MotionBurstGate = MotionBurstGate()
    ) {
        self.profiles = profiles
        self.matcher = matcher
        self.segmenter = segmenter
        self.burstGate = burstGate
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
            burstGateRejectionReason: evaluation.burstGateRejectionReason
        )
    }

    public func bestCandidate(for segment: GestureSegment, now: Double? = nil) -> RecognitionCandidate? {
        evaluate(segment: segment, now: now).candidate
    }

    public func evaluate(segment: GestureSegment, now: Double? = nil) -> RecognitionEvaluation {
        let matchingProfiles = profiles.filter { $0.kind == segment.kind || $0.kind == .combo }
        var burstGateRejectionReason: BurstGateRejectionReason?
        let gatedProfiles = matchingProfiles.filter { profile in
            let decision = burstGate.decision(for: segment, profile: profile)
            if decision.isAllowed {
                return true
            }
            if burstGateRejectionReason == nil {
                burstGateRejectionReason = decision.reason
            }
            return false
        }

        let candidate = matcher.bestMatch(
            profiles: gatedProfiles,
            candidateSamples: segment.samples,
            lastTriggerTimes: lastTriggerTimes,
            now: now
        )

        return RecognitionEvaluation(
            candidate: candidate,
            burstGateRejectionReason: candidate == nil ? burstGateRejectionReason : nil
        )
    }

    public func eligibleProfiles(for segment: GestureSegment) -> [GestureProfile] {
        let matchingProfiles = profiles.filter { $0.kind == segment.kind || $0.kind == .combo }
        return matchingProfiles.filter { burstGate.decision(for: segment, profile: $0).isAllowed }
    }

    public func burstGateDecision(for segment: GestureSegment, profile: GestureProfile) -> BurstGateDecision {
        burstGate.decision(for: segment, profile: profile)
    }

    public mutating func record(
        segment: GestureSegment,
        candidate: RecognitionCandidate?,
        now: Double? = nil,
        batteryLevel: Double? = nil,
        wearContext: WearContext? = nil,
        audioPlayed: Bool = false,
        burstGateRejectionReason: BurstGateRejectionReason? = nil
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
            burstGateRejectionReason: burstGateRejectionReason
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
        burstGateRejectionReason: BurstGateRejectionReason?
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
            burstGateRejectionReason: burstGateRejectionReason
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
