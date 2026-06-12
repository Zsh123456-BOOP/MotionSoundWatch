import Foundation

public struct MotionVector3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }

    public static func - (lhs: MotionVector3, rhs: MotionVector3) -> MotionVector3 {
        MotionVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }
}

public struct MotionQuaternion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

public struct MotionSample: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var userAcceleration: MotionVector3
    public var rotationRate: MotionVector3
    public var gravity: MotionVector3?
    public var attitude: MotionQuaternion?

    public init(
        timestamp: Double,
        userAcceleration: MotionVector3,
        rotationRate: MotionVector3,
        gravity: MotionVector3? = nil,
        attitude: MotionQuaternion? = nil
    ) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.attitude = attitude
    }
}

public enum GestureKind: String, Codable, Equatable, Sendable {
    case burst
    case sequence
    case posture
    case combo
}

public enum TriggerTiming: String, Codable, Equatable, Sendable {
    case atPeak
    case atEnd
    case afterHold
    case customDelay
}

public struct WearContext: Codable, Equatable, Sendable {
    public var wristLocation: String
    public var crownOrientation: String
    public var watchModel: String?
    public var osVersion: String?

    public init(
        wristLocation: String,
        crownOrientation: String,
        watchModel: String? = nil,
        osVersion: String? = nil
    ) {
        self.wristLocation = wristLocation
        self.crownOrientation = crownOrientation
        self.watchModel = watchModel
        self.osVersion = osVersion
    }
}

public struct SoundAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public var duration: Double
    public var volume: Float
    public var localWatchPath: String?
    public var checksum: String?

    public init(
        id: UUID = UUID(),
        fileName: String,
        duration: Double,
        volume: Float = 1,
        localWatchPath: String? = nil,
        checksum: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.duration = duration
        self.volume = volume
        self.localWatchPath = localWatchPath
        self.checksum = checksum
    }
}

public struct GestureFeatures: Codable, Equatable, Sendable {
    public var duration: Double
    public var peakAcceleration: Double
    public var peakRotationRate: Double
    public var peakJerk: Double
    public var meanEnergy: Double
    public var dominantAxis: Int
    public var energyShape: [Double]

    public init(
        duration: Double,
        peakAcceleration: Double,
        peakRotationRate: Double,
        peakJerk: Double,
        meanEnergy: Double,
        dominantAxis: Int,
        energyShape: [Double]
    ) {
        self.duration = duration
        self.peakAcceleration = peakAcceleration
        self.peakRotationRate = peakRotationRate
        self.peakJerk = peakJerk
        self.meanEnergy = meanEnergy
        self.dominantAxis = dominantAxis
        self.energyShape = energyShape
    }
}

public struct GestureQuality: Codable, Equatable, Sendable {
    public var score: Double
    public var warnings: [String]

    public init(score: Double, warnings: [String] = []) {
        self.score = score
        self.warnings = warnings
    }
}

public struct MotionTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var kind: GestureKind
    public var samples: [MotionSample]
    public var rawDuration: Double
    public var sampleRate: Double
    public var features: GestureFeatures?
    public var qualityScore: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        kind: GestureKind,
        samples: [MotionSample],
        rawDuration: Double? = nil,
        sampleRate: Double? = nil,
        features: GestureFeatures? = nil,
        qualityScore: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.samples = samples
        self.rawDuration = rawDuration ?? Self.duration(samples)
        self.sampleRate = sampleRate ?? Self.sampleRate(samples)
        self.features = features
        self.qualityScore = qualityScore
        self.createdAt = createdAt
    }

    private static func duration(_ samples: [MotionSample]) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.timestamp - first.timestamp)
    }

    private static func sampleRate(_ samples: [MotionSample]) -> Double {
        let duration = duration(samples)
        guard duration > 0, samples.count > 1 else { return 0 }
        return Double(samples.count - 1) / duration
    }
}

public struct GestureProfile: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var kind: GestureKind
    public var templates: [MotionTemplate]
    public var negativeTemplates: [MotionTemplate]
    public var acceptanceThreshold: Double
    public var marginThreshold: Double
    public var cooldownSeconds: Double
    public var strictness: Double
    public var sound: SoundAsset?
    public var soundSequence: [SoundAsset]?
    public var audioAssetName: String?
    public var triggerTiming: TriggerTiming
    public var customDelayMilliseconds: Int?
    public var wearContext: WearContext?
    public var signature: GestureSignature?
    public var signatureVariants: [GestureProfileVariant]?
    public var thresholds: ThresholdProfile?
    public var triggerPolicy: TriggerPolicy?
    public var quality: GestureQuality
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        name: String,
        kind: GestureKind,
        templates: [MotionTemplate],
        negativeTemplates: [MotionTemplate] = [],
        acceptanceThreshold: Double,
        marginThreshold: Double = 0,
        cooldownSeconds: Double = 0.8,
        strictness: Double = 0.5,
        sound: SoundAsset? = nil,
        soundSequence: [SoundAsset]? = nil,
        audioAssetName: String? = nil,
        triggerTiming: TriggerTiming? = nil,
        customDelayMilliseconds: Int? = nil,
        wearContext: WearContext? = nil,
        signature: GestureSignature? = nil,
        signatureVariants: [GestureProfileVariant]? = nil,
        thresholds: ThresholdProfile? = nil,
        triggerPolicy: TriggerPolicy? = nil,
        quality: GestureQuality = GestureQuality(score: 0.5),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.kind = kind
        self.templates = templates
        self.negativeTemplates = negativeTemplates
        self.acceptanceThreshold = acceptanceThreshold
        self.marginThreshold = marginThreshold
        self.cooldownSeconds = cooldownSeconds
        self.strictness = strictness
        self.sound = sound
        self.soundSequence = soundSequence
        self.audioAssetName = audioAssetName
        self.triggerTiming = triggerTiming ?? Self.defaultTriggerTiming(for: kind)
        self.customDelayMilliseconds = customDelayMilliseconds
        self.wearContext = wearContext
        self.signature = signature
        self.signatureVariants = signatureVariants
        self.thresholds = thresholds
        self.triggerPolicy = triggerPolicy
        self.quality = quality
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private static func defaultTriggerTiming(for kind: GestureKind) -> TriggerTiming {
        switch kind {
        case .burst:
            return .atPeak
        case .sequence:
            return .atEnd
        case .posture:
            return .afterHold
        case .combo:
            return .atEnd
        }
    }
}

public struct RecordingAssessment: Equatable, Sendable {
    public var duration: Double
    public var sampleCount: Int
    public var estimatedSampleRate: Double
    public var errors: [String]
    public var warnings: [String]

    public var canSave: Bool {
        errors.isEmpty
    }
}

public struct RecordingQualityReport: Codable, Equatable, Sendable {
    public var canUseForTraining: Bool
    public var shouldAskRerecord: Bool
    public var detectedKind: MotionTokenKind
    public var duration: Double
    public var sampleRate: Double
    public var energyScore: Double
    public var stabilityScore: Double
    public var clippingRisk: Double
    public var similarityToExistingSamples: Double?
    public var warnings: [String]
    public var errors: [String]

    public init(
        canUseForTraining: Bool,
        shouldAskRerecord: Bool,
        detectedKind: MotionTokenKind,
        duration: Double,
        sampleRate: Double,
        energyScore: Double,
        stabilityScore: Double,
        clippingRisk: Double,
        similarityToExistingSamples: Double? = nil,
        warnings: [String] = [],
        errors: [String] = []
    ) {
        self.canUseForTraining = canUseForTraining
        self.shouldAskRerecord = shouldAskRerecord
        self.detectedKind = detectedKind
        self.duration = duration
        self.sampleRate = sampleRate
        self.energyScore = energyScore
        self.stabilityScore = stabilityScore
        self.clippingRisk = clippingRisk
        self.similarityToExistingSamples = similarityToExistingSamples
        self.warnings = warnings
        self.errors = errors
    }
}

public struct MotionRecordingValidator: Sendable {
    public var shortDurationHint: Double
    public var longDurationHint: Double
    public var minimumSamples: Int
    public var minimumSampleRate: Double

    public init(
        shortDurationHint: Double = 0.25,
        longDurationHint: Double = 4.0,
        minimumSamples: Int = 12,
        minimumSampleRate: Double = 30
    ) {
        self.shortDurationHint = shortDurationHint
        self.longDurationHint = longDurationHint
        self.minimumSamples = minimumSamples
        self.minimumSampleRate = minimumSampleRate
    }

    public func assess(_ samples: [MotionSample]) -> RecordingAssessment {
        guard samples.count >= 2 else {
            return RecordingAssessment(
                duration: 0,
                sampleCount: samples.count,
                estimatedSampleRate: 0,
                errors: ["录制样本太少，无法保存为动作模板。"],
                warnings: []
            )
        }

        var errors: [String] = []
        var warnings: [String] = []

        for pair in zip(samples, samples.dropFirst()) where pair.1.timestamp <= pair.0.timestamp {
            errors.append("传感器时间戳不是递增序列。")
            break
        }

        let duration = max(0, samples.last!.timestamp - samples.first!.timestamp)
        let estimatedSampleRate = duration > 0 ? Double(samples.count - 1) / duration : 0

        if samples.count < minimumSamples {
            errors.append("录制样本少于 \(minimumSamples) 个。")
        }

        if duration < shortDurationHint {
            warnings.append("这是短促动作，建议归类为 burst，并使用峰值触发与较短冷却。")
        }

        if duration > longDurationHint {
            warnings.append("这是长动作，建议归类为 sequence，并考虑分段或关键帧匹配。")
        }

        if peakEnergy(samples) < 0.08 {
            warnings.append("动作幅度较低，后续容易与日常手腕移动混淆。")
        }

        return RecordingAssessment(
            duration: duration,
            sampleCount: samples.count,
            estimatedSampleRate: estimatedSampleRate,
            errors: errors,
            warnings: warnings
        )
    }

    public func qualityReport(
        samples: [MotionSample],
        draftKind: GestureKind,
        existingPositiveTemplates: [MotionTemplate] = [],
        existingNegativeTemplates: [MotionTemplate] = []
    ) -> RecordingQualityReport {
        let assessment = assess(samples)
        let extractor = MotionFeatureExtractor()
        let tokenizer = MotionTokenizer()
        let matcher = MotionTemplateMatcher()
        let features = extractor.extract(samples)
        let detectedKind = tokenizer.classify(features)

        var warnings = assessment.warnings
        let errors = assessment.errors
        var shouldAskRerecord = false

        if assessment.estimatedSampleRate > 0, assessment.estimatedSampleRate < minimumSampleRate {
            warnings.append("采样率低于 \(Int(minimumSampleRate))Hz，建议重录以提升识别稳定性。")
            shouldAskRerecord = true
        }

        if !Self.kind(detectedKind, matches: draftKind) {
            warnings.append("这次动作和当前动作类型不一致，建议重录。")
            shouldAskRerecord = true
        }

        let energyScore = min(1, max(features.peakAcc, features.meanAcc * 2.0) / 1.2)
        if energyScore < 0.18 {
            warnings.append("动作幅度太低，容易被日常移动淹没，建议重录。")
            shouldAskRerecord = true
        }

        let stabilityScore = Self.stabilityScore(features: features, detectedKind: detectedKind)
        let clippingRisk = Self.clippingRisk(samples)
        if clippingRisk > 0.08 {
            warnings.append("录制片段存在较高削顶风险，建议降低动作冲击或重录。")
            shouldAskRerecord = true
        }

        let similarityToExistingSamples = existingPositiveTemplates
            .map { matcher.distance($0.samples, samples) }
            .min()
        if let similarityToExistingSamples {
            let positiveSpread = Self.positiveDistanceSpread(existingPositiveTemplates, matcher: matcher)
            let farThreshold = max(0.42, positiveSpread * 1.8)
            if similarityToExistingSamples > farThreshold {
                warnings.append("这次动作和前几次不一致，建议重录。")
                shouldAskRerecord = true
            }
        }

        let nearestNegativeDistance = existingNegativeTemplates
            .map { matcher.distance($0.samples, samples) }
            .min()
        if let nearestNegativeDistance, nearestNegativeDistance < 0.28 {
            warnings.append("这次录制接近已有误触样本，误触风险高。")
            shouldAskRerecord = true
        }

        let canUseForTraining = errors.isEmpty && !shouldAskRerecord
        return RecordingQualityReport(
            canUseForTraining: canUseForTraining,
            shouldAskRerecord: shouldAskRerecord,
            detectedKind: detectedKind,
            duration: assessment.duration,
            sampleRate: assessment.estimatedSampleRate,
            energyScore: energyScore,
            stabilityScore: stabilityScore,
            clippingRisk: clippingRisk,
            similarityToExistingSamples: similarityToExistingSamples,
            warnings: warnings,
            errors: errors
        )
    }

    private func peakEnergy(_ samples: [MotionSample]) -> Double {
        samples.map { $0.userAcceleration.magnitude + 0.25 * $0.rotationRate.magnitude }.max() ?? 0
    }

    private static func kind(_ detectedKind: MotionTokenKind, matches draftKind: GestureKind) -> Bool {
        switch draftKind {
        case .burst:
            return detectedKind == .impulse || detectedKind == .sweep || detectedKind == .free
        case .sequence:
            return detectedKind == .rotation || detectedKind == .oscillation || detectedKind == .sweep || detectedKind == .free
        case .posture:
            return detectedKind == .hold || detectedKind == .pause || detectedKind == .free
        case .combo:
            return true
        }
    }

    private static func stabilityScore(features: GestureSampleFeatures, detectedKind: MotionTokenKind) -> Double {
        switch detectedKind {
        case .rotation:
            return features.rotationAxisStability
        case .oscillation:
            return features.periodicityScore
        case .hold:
            return features.holdStability
        default:
            return min(1, features.directionalityScore)
        }
    }

    private static func clippingRisk(_ samples: [MotionSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let clipped = samples.filter {
            $0.userAcceleration.magnitude >= 2.7 || $0.rotationRate.magnitude >= 18
        }.count
        return Double(clipped) / Double(samples.count)
    }

    private static func positiveDistanceSpread(
        _ templates: [MotionTemplate],
        matcher: MotionTemplateMatcher
    ) -> Double {
        guard templates.count >= 2 else { return 0.24 }
        var distances: [Double] = []
        for i in templates.indices {
            for j in templates.indices where j > i {
                distances.append(matcher.distance(templates[i].samples, templates[j].samples))
            }
        }
        return distances.max() ?? 0.24
    }
}

public struct RecognitionCandidate: Equatable, Sendable {
    public var profile: GestureProfile
    public var distance: Double
    public var secondBestDistance: Double?
    public var margin: Double?
    public var confidence: Double
    public var templateID: UUID
    public var recognitionScore: Double?
    public var recognizerKind: MotionTokenKind?
    public var rejectReason: RejectReason?
    public var variantID: UUID?
    public var variantLabel: String?

    public var shouldTrigger: Bool {
        guard rejectReason == nil else {
            return false
        }
        if let recognitionScore, let thresholds = profile.thresholds {
            let passesScore = recognitionScore >= thresholds.triggerScore
            let passesMargin = (margin ?? .infinity) >= thresholds.marginScore
            return passesScore && passesMargin
        } else {
            let passesDistance = distance <= profile.acceptanceThreshold
            let passesMargin = (margin ?? .infinity) >= profile.marginThreshold
            return passesDistance && passesMargin
        }
    }

    public init(
        profile: GestureProfile,
        distance: Double,
        secondBestDistance: Double? = nil,
        margin: Double? = nil,
        confidence: Double,
        templateID: UUID,
        recognitionScore: Double? = nil,
        recognizerKind: MotionTokenKind? = nil,
        rejectReason: RejectReason? = nil,
        variantID: UUID? = nil,
        variantLabel: String? = nil
    ) {
        self.profile = profile
        self.distance = distance
        self.secondBestDistance = secondBestDistance
        self.margin = margin
        self.confidence = confidence
        self.templateID = templateID
        self.recognitionScore = recognitionScore
        self.recognizerKind = recognizerKind
        self.rejectReason = rejectReason
        self.variantID = variantID
        self.variantLabel = variantLabel
    }
}

public struct ThresholdCalibration: Equatable, Sendable {
    public var threshold: Double
    public var positiveMaxDistance: Double
    public var negativeMinDistance: Double?
    public var margin: Double
    public var recommendedMarginThreshold: Double
}

public struct CalibrationReport: Codable, Equatable, Sendable {
    public var threshold: Double
    public var triggerScore: Double
    public var marginScore: Double
    public var positiveRecallEstimate: Double
    public var negativeFalseTriggerEstimate: Double
    public var separationScore: Double
    public var hardNegativeCount: Int
    public var recommendedStrictness: Double
    public var warnings: [String]

    public init(
        threshold: Double,
        triggerScore: Double,
        marginScore: Double,
        positiveRecallEstimate: Double,
        negativeFalseTriggerEstimate: Double,
        separationScore: Double,
        hardNegativeCount: Int,
        recommendedStrictness: Double,
        warnings: [String] = []
    ) {
        self.threshold = threshold
        self.triggerScore = triggerScore
        self.marginScore = marginScore
        self.positiveRecallEstimate = positiveRecallEstimate
        self.negativeFalseTriggerEstimate = negativeFalseTriggerEstimate
        self.separationScore = separationScore
        self.hardNegativeCount = hardNegativeCount
        self.recommendedStrictness = recommendedStrictness
        self.warnings = warnings
    }
}

public struct MotionTemplateMatcher: Sendable {
    public var targetSampleCount: Int
    public var sakoeChibaRadius: Int
    /// 匹配前对模板与候选统一应用的低通滤波（两侧一致，保证距离可比）。
    public var lowPassFilter: MotionLowPassFilter

    public init(
        targetSampleCount: Int = 48,
        sakoeChibaRadius: Int = 8,
        lowPassFilter: MotionLowPassFilter = MotionLowPassFilter()
    ) {
        self.targetSampleCount = targetSampleCount
        self.sakoeChibaRadius = sakoeChibaRadius
        self.lowPassFilter = lowPassFilter
    }

    public func bestMatch(
        profiles: [GestureProfile],
        candidateSamples: [MotionSample],
        lastTriggerTimes: [UUID: Double] = [:],
        now: Double? = nil
    ) -> RecognitionCandidate? {
        var best: RecognitionCandidate?

        for profile in profiles where !profile.templates.isEmpty {
            if let now, let last = lastTriggerTimes[profile.id], now - last < profile.cooldownSeconds {
                continue
            }

            guard let match = bestTemplateDistance(profile: profile, candidateSamples: candidateSamples) else {
                continue
            }

            let confidence = confidenceScore(distance: match.distance, threshold: profile.acceptanceThreshold)
            let candidate = RecognitionCandidate(
                profile: profile,
                distance: match.distance,
                secondBestDistance: match.secondBestDistance,
                margin: match.margin,
                confidence: confidence,
                templateID: match.templateID
            )

            if best == nil || candidate.distance < best!.distance {
                best = candidate
            }
        }

        return best
    }

    public func distance(_ lhs: [MotionSample], _ rhs: [MotionSample]) -> Double {
        let leftFrames = normalize(resample(lowPassFilter.filtered(lhs), targetCount: targetSampleCount))
        let rightFrames = normalize(resample(lowPassFilter.filtered(rhs), targetCount: targetSampleCount))
        return dynamicTimeWarping(leftFrames, rightFrames, radius: sakoeChibaRadius)
    }

    public func calibrateThreshold(
        positiveTemplates: [MotionTemplate],
        negativeWindows: [[MotionSample]] = [],
        paddingRatio: Double = 0.18
    ) -> ThresholdCalibration {
        let report = calibrationReport(positiveTemplates: positiveTemplates, negativeWindows: negativeWindows)
        guard positiveTemplates.count >= 2 else {
            return ThresholdCalibration(
                threshold: report.threshold,
                positiveMaxDistance: 0,
                negativeMinDistance: nil,
                margin: report.threshold,
                recommendedMarginThreshold: report.marginScore
            )
        }

        var positiveDistances: [Double] = []
        for i in positiveTemplates.indices {
            for j in positiveTemplates.indices where j > i {
                positiveDistances.append(distance(positiveTemplates[i].samples, positiveTemplates[j].samples))
            }
        }

        let positiveMax = positiveDistances.max() ?? 0.25
        let negativeMin = negativeWindows
            .flatMap { negative in positiveTemplates.map { distance($0.samples, negative) } }
            .min()

        let threshold = min(report.threshold, negativeMin.map { max(positiveMax + 0.02, $0 * 0.88) } ?? report.threshold)

        return ThresholdCalibration(
            threshold: threshold,
            positiveMaxDistance: positiveMax,
            negativeMinDistance: negativeMin,
            margin: (negativeMin ?? threshold) - positiveMax,
            recommendedMarginThreshold: max(report.marginScore, max(0, ((negativeMin ?? threshold) - positiveMax) * 0.25))
        )
    }

    public func calibrationReport(
        positiveTemplates: [MotionTemplate],
        negativeWindows: [[MotionSample]] = []
    ) -> CalibrationReport {
        var warnings: [String] = []
        guard positiveTemplates.count >= 2 else {
            warnings.append("单模板风险高，建议至少录制 3 次。")
            return CalibrationReport(
                threshold: 0.30,
                triggerScore: 0.80,
                marginScore: 0.14,
                positiveRecallEstimate: positiveTemplates.isEmpty ? 0 : 1,
                negativeFalseTriggerEstimate: 0,
                separationScore: 0,
                hardNegativeCount: negativeWindows.count,
                recommendedStrictness: 0.72,
                warnings: warnings
            )
        }

        var leaveOneOutDistances: [Double] = []
        for index in positiveTemplates.indices {
            let candidate = positiveTemplates[index]
            let others = positiveTemplates.enumerated()
                .filter { $0.offset != index }
                .map(\.element)
            let nearest = others
                .map { distance($0.samples, candidate.samples) }
                .min()
            if let nearest {
                leaveOneOutDistances.append(nearest)
            }
        }

        var pairwisePositiveDistances: [Double] = []
        for i in positiveTemplates.indices {
            for j in positiveTemplates.indices where j > i {
                pairwisePositiveDistances.append(distance(positiveTemplates[i].samples, positiveTemplates[j].samples))
            }
        }

        let positiveP50 = percentile(leaveOneOutDistances, pct: 0.50) ?? 0.20
        let positiveP80 = percentile(leaveOneOutDistances, pct: 0.80) ?? positiveP50
        let positiveP95 = percentile(leaveOneOutDistances, pct: 0.95) ?? positiveP80
        let positiveMax = pairwisePositiveDistances.max() ?? positiveP95
        if positiveMax > max(0.42, positiveP50 * 2.2) {
            warnings.append("正样本内部差异过大，存在离群录制。")
        }

        let negativeDistances = negativeWindows.flatMap { negative in
            positiveTemplates.map { distance($0.samples, negative) }
        }
        let negativeP05 = percentile(negativeDistances, pct: 0.05)
        let negativeMin = negativeDistances.min()
        let targetPositive = max(positiveP80 + 0.03, positiveP95 * 1.04)
        let threshold: Double
        if let negativeP05 {
            threshold = min(targetPositive, max(positiveP80 + 0.015, negativeP05 * 0.82))
        } else {
            threshold = targetPositive
        }

        let positiveRecall = leaveOneOutDistances.isEmpty
            ? 0
            : Double(leaveOneOutDistances.filter { $0 <= threshold }.count) / Double(leaveOneOutDistances.count)
        let negativeFalseTrigger = negativeDistances.isEmpty
            ? 0
            : Double(negativeDistances.filter { $0 <= threshold }.count) / Double(negativeDistances.count)
        let separation = max(0, ((negativeP05 ?? threshold) - positiveP80) / max(negativeP05 ?? threshold, 0.0001))
        let hardNegativeCount = negativeDistances.filter { $0 <= positiveP95 * 1.35 }.count

        if let negativeMin, negativeMin <= positiveP95 {
            warnings.append("正样本和负样本距离重叠，容易误触发。")
        }
        if negativeFalseTrigger > 0 {
            warnings.append("负样本接近阈值，建议提高严格度或补充 hard negative。")
        }

        let strictness = min(1, max(0.35, 0.55 + Double(hardNegativeCount) * 0.04 + negativeFalseTrigger * 0.20 - separation * 0.10))
        return CalibrationReport(
            threshold: threshold,
            triggerScore: min(0.90, max(0.58, 1 - threshold * 0.62 + strictness * 0.06)),
            marginScore: max(0.04, separation * 0.18),
            positiveRecallEstimate: positiveRecall,
            negativeFalseTriggerEstimate: negativeFalseTrigger,
            separationScore: separation,
            hardNegativeCount: hardNegativeCount,
            recommendedStrictness: strictness,
            warnings: warnings
        )
    }

    private func percentile(_ values: [Double], pct: Double) -> Double? {
        let ordered = values.filter { $0.isFinite }.sorted()
        guard !ordered.isEmpty else { return nil }
        guard ordered.count > 1 else { return ordered[0] }
        let clamped = max(0, min(1, pct))
        let position = Double(ordered.count - 1) * clamped
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return ordered[lower]
        }
        let fraction = position - Double(lower)
        return ordered[lower] * (1 - fraction) + ordered[upper] * fraction
    }

    private func bestTemplateDistance(
        profile: GestureProfile,
        candidateSamples: [MotionSample]
    ) -> (distance: Double, secondBestDistance: Double?, margin: Double?, templateID: UUID)? {
        let ranked = profile.templates
            .map { template in
                (
                    completeTrajectoryDistance(template.samples, candidateSamples: candidateSamples),
                    template.id
                )
            }
            .sorted { $0.0 < $1.0 }

        guard let best = ranked.first else { return nil }
        let secondBestDistance = ranked.dropFirst().first?.0
        let margin = secondBestDistance.map { $0 - best.0 }
        return (distance: best.0, secondBestDistance: secondBestDistance, margin: margin, templateID: best.1)
    }

    private func completeTrajectoryDistance(
        _ templateSamples: [MotionSample],
        candidateSamples: [MotionSample]
    ) -> Double {
        let baseDistance = distance(templateSamples, candidateSamples)
        let templateDuration = duration(of: templateSamples)
        let candidateDuration = duration(of: candidateSamples)
        guard templateDuration > 0.05, candidateDuration > 0.05 else {
            return baseDistance + 0.20
        }

        let ratio = candidateDuration / templateDuration
        let durationPenalty: Double
        if ratio >= 0.72, ratio <= 1.45 {
            durationPenalty = 0
        } else if ratio < 0.72 {
            durationPenalty = min(0.28, (0.72 - ratio) * 0.55)
        } else {
            durationPenalty = min(0.04, (ratio - 1.45) * 0.035)
        }

        return baseDistance + durationPenalty
    }

    private func duration(of samples: [MotionSample]) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.timestamp - first.timestamp)
    }

    private func confidenceScore(distance: Double, threshold: Double) -> Double {
        guard threshold > 0 else { return 0 }
        return max(0, min(1, 1 - distance / (threshold * 1.35)))
    }
}

private struct MotionFeatureFrame: Equatable {
    var values: [Double]
}

private func resample(_ samples: [MotionSample], targetCount: Int) -> [MotionSample] {
    guard samples.count > 1, targetCount > 1 else { return samples }

    let start = samples.first!.timestamp
    let end = samples.last!.timestamp
    let duration = end - start
    guard duration > 0 else { return samples }

    var output: [MotionSample] = []
    output.reserveCapacity(targetCount)

    var sourceIndex = 0
    for index in 0..<targetCount {
        let t = start + duration * Double(index) / Double(targetCount - 1)
        while sourceIndex < samples.count - 2, samples[sourceIndex + 1].timestamp < t {
            sourceIndex += 1
        }

        let left = samples[sourceIndex]
        let right = samples[min(sourceIndex + 1, samples.count - 1)]
        let span = max(right.timestamp - left.timestamp, .leastNonzeroMagnitude)
        let alpha = max(0, min(1, (t - left.timestamp) / span))

        output.append(MotionSample(
            timestamp: t - start,
            userAcceleration: interpolate(left.userAcceleration, right.userAcceleration, alpha: alpha),
            rotationRate: interpolate(left.rotationRate, right.rotationRate, alpha: alpha),
            gravity: interpolateOptional(left.gravity, right.gravity, alpha: alpha),
            attitude: interpolateOptional(left.attitude, right.attitude, alpha: alpha)
        ))
    }

    return output
}

private func normalize(_ samples: [MotionSample]) -> [MotionFeatureFrame] {
    guard !samples.isEmpty else { return [] }

    let localized = localizeToInitialAttitude(samples)
    let raw = localized.map {
        [
            $0.userAcceleration.x,
            $0.userAcceleration.y,
            $0.userAcceleration.z,
            $0.rotationRate.x * 0.35,
            $0.rotationRate.y * 0.35,
            $0.rotationRate.z * 0.35,
        ]
    }

    let columns = raw[0].indices.map { column in raw.map { $0[column] } }
    let means = columns.map { values in values.reduce(0, +) / Double(values.count) }
    let centered = raw.map { row in
        row.indices.map { row[$0] - means[$0] }
    }
    // 尺度用全通道 |值| 的最大值（保留通道间幅度比例 → 主轴判别）。
    // 注：单样本尖峰压扁其余维度的问题已由 Phase 2 的低通滤波在上游消除，
    // 因此这里无需改用 p95 之类的鲁棒统计量（那样会整体抬高距离、使已校准阈值失效）。
    let scale = max(
        centered.flatMap { $0 }.map { abs($0) }.max() ?? 1,
        0.001
    )

    return centered.map { row in
        MotionFeatureFrame(values: row.map { $0 / scale })
    }
}

private func localizeToInitialAttitude(_ samples: [MotionSample]) -> [MotionSample] {
    guard let initialAttitude = samples.first(where: { $0.attitude != nil })?.attitude else {
        return samples
    }
    let inverseInitial = inverse(initialAttitude)
    return samples.map { sample in
        MotionSample(
            timestamp: sample.timestamp,
            userAcceleration: rotate(sample.userAcceleration, by: inverseInitial),
            rotationRate: rotate(sample.rotationRate, by: inverseInitial),
            gravity: sample.gravity.map { rotate($0, by: inverseInitial) },
            attitude: sample.attitude
        )
    }
}

private func dynamicTimeWarping(
    _ lhs: [MotionFeatureFrame],
    _ rhs: [MotionFeatureFrame],
    radius: Int
) -> Double {
    guard !lhs.isEmpty, !rhs.isEmpty else { return .infinity }

    let n = lhs.count
    let m = rhs.count
    let window = max(radius, abs(n - m))
    var previous = Array(repeating: Double.infinity, count: m + 1)
    var current = Array(repeating: Double.infinity, count: m + 1)
    previous[0] = 0

    for i in 1...n {
        current = Array(repeating: Double.infinity, count: m + 1)
        let lower = max(1, i - window)
        let upper = min(m, i + window)

        for j in lower...upper {
            let cost = euclidean(lhs[i - 1].values, rhs[j - 1].values)
            current[j] = cost + min(previous[j], current[j - 1], previous[j - 1])
        }

        previous = current
    }

    return previous[m] / Double(n + m)
}

private func euclidean(_ lhs: [Double], _ rhs: [Double]) -> Double {
    sqrt(zip(lhs, rhs).map { pow($0 - $1, 2) }.reduce(0, +))
}

private func interpolate(_ lhs: MotionVector3, _ rhs: MotionVector3, alpha: Double) -> MotionVector3 {
    MotionVector3(
        x: lhs.x + (rhs.x - lhs.x) * alpha,
        y: lhs.y + (rhs.y - lhs.y) * alpha,
        z: lhs.z + (rhs.z - lhs.z) * alpha
    )
}

private func interpolateOptional(_ lhs: MotionVector3?, _ rhs: MotionVector3?, alpha: Double) -> MotionVector3? {
    guard let lhs, let rhs else { return lhs ?? rhs }
    return interpolate(lhs, rhs, alpha: alpha)
}

private func interpolateOptional(_ lhs: MotionQuaternion?, _ rhs: MotionQuaternion?, alpha: Double) -> MotionQuaternion? {
    guard let lhs, let rhs else { return lhs ?? rhs }
    return normalized(
        MotionQuaternion(
            x: lhs.x + (rhs.x - lhs.x) * alpha,
            y: lhs.y + (rhs.y - lhs.y) * alpha,
            z: lhs.z + (rhs.z - lhs.z) * alpha,
            w: lhs.w + (rhs.w - lhs.w) * alpha
        )
    )
}

private func normalized(_ quaternion: MotionQuaternion) -> MotionQuaternion {
    let magnitude = sqrt(
        quaternion.x * quaternion.x
            + quaternion.y * quaternion.y
            + quaternion.z * quaternion.z
            + quaternion.w * quaternion.w
    )
    guard magnitude > 0.000001 else {
        return MotionQuaternion(x: 0, y: 0, z: 0, w: 1)
    }
    return MotionQuaternion(
        x: quaternion.x / magnitude,
        y: quaternion.y / magnitude,
        z: quaternion.z / magnitude,
        w: quaternion.w / magnitude
    )
}

private func inverse(_ quaternion: MotionQuaternion) -> MotionQuaternion {
    let q = normalized(quaternion)
    return MotionQuaternion(x: -q.x, y: -q.y, z: -q.z, w: q.w)
}

private func rotate(_ vector: MotionVector3, by quaternion: MotionQuaternion) -> MotionVector3 {
    let q = normalized(quaternion)
    let u = MotionVector3(x: q.x, y: q.y, z: q.z)
    let s = q.w
    let dotUV = dot(u, vector)
    let dotUU = dot(u, u)
    let crossUV = cross(u, vector)
    return MotionVector3(
        x: 2 * dotUV * u.x + (s * s - dotUU) * vector.x + 2 * s * crossUV.x,
        y: 2 * dotUV * u.y + (s * s - dotUU) * vector.y + 2 * s * crossUV.y,
        z: 2 * dotUV * u.z + (s * s - dotUU) * vector.z + 2 * s * crossUV.z
    )
}

private func dot(_ lhs: MotionVector3, _ rhs: MotionVector3) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}

private func cross(_ lhs: MotionVector3, _ rhs: MotionVector3) -> MotionVector3 {
    MotionVector3(
        x: lhs.y * rhs.z - lhs.z * rhs.y,
        y: lhs.z * rhs.x - lhs.x * rhs.z,
        z: lhs.x * rhs.y - lhs.y * rhs.x
    )
}
