import Foundation

public enum GestureReliability: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

public struct GestureQualityReport: Codable, Equatable, Sendable {
    public var score: Double
    public var reliability: GestureReliability
    public var warnings: [String]
    public var positiveMaxDistance: Double?
    public var negativeMinDistance: Double?
    public var conflictDistance: Double?

    public init(
        score: Double,
        reliability: GestureReliability,
        warnings: [String] = [],
        positiveMaxDistance: Double? = nil,
        negativeMinDistance: Double? = nil,
        conflictDistance: Double? = nil
    ) {
        self.score = score
        self.reliability = reliability
        self.warnings = warnings
        self.positiveMaxDistance = positiveMaxDistance
        self.negativeMinDistance = negativeMinDistance
        self.conflictDistance = conflictDistance
    }

    public var quality: GestureQuality {
        GestureQuality(score: score, warnings: warnings)
    }
}

public struct MotionTemplateBuilder: Sendable {
    public var validator: MotionRecordingValidator
    public var energyAnalyzer: MotionEnergyAnalyzer

    public init(
        validator: MotionRecordingValidator = MotionRecordingValidator(),
        energyAnalyzer: MotionEnergyAnalyzer = MotionEnergyAnalyzer()
    ) {
        self.validator = validator
        self.energyAnalyzer = energyAnalyzer
    }

    public func makeTemplate(
        label: String,
        kind: GestureKind,
        samples: [MotionSample],
        createdAt: Date = Date()
    ) -> MotionTemplate {
        let assessment = validator.assess(samples)
        let features = energyAnalyzer.features(for: samples)
        let qualityScore = baseQualityScore(assessment: assessment, features: features)

        return MotionTemplate(
            label: label,
            kind: kind,
            samples: samples,
            features: features,
            qualityScore: qualityScore,
            createdAt: createdAt
        )
    }

    public func makeTemplate(label: String, segment: GestureSegment, createdAt: Date = Date()) -> MotionTemplate {
        MotionTemplate(
            label: label,
            kind: segment.kind,
            samples: segment.samples,
            features: segment.features,
            qualityScore: baseQualityScore(assessment: validator.assess(segment.samples), features: segment.features),
            createdAt: createdAt
        )
    }

    private func baseQualityScore(assessment: RecordingAssessment, features: GestureFeatures) -> Double {
        var score = 1.0
        score -= Double(assessment.errors.count) * 0.35
        score -= Double(assessment.warnings.count) * 0.12

        if features.peakAcceleration < 0.15 {
            score -= 0.2
        }

        if features.peakJerk < 0.5 {
            score -= 0.1
        }

        return max(0, min(1, score))
    }
}

public struct GestureQualityEvaluator: Sendable {
    public var matcher: MotionTemplateMatcher

    public init(matcher: MotionTemplateMatcher = MotionTemplateMatcher()) {
        self.matcher = matcher
    }

    public func evaluate(
        templates: [MotionTemplate],
        negativeTemplates: [MotionTemplate] = [],
        existingProfiles: [GestureProfile] = []
    ) -> GestureQualityReport {
        var warnings: [String] = []

        if templates.count == 1 {
            warnings.append("仅录制 1 次，可靠性较低，建议至少录制 3 次。")
        } else if templates.count < 3 {
            warnings.append("模板数量偏少，建议录制 3-5 次。")
        }

        let calibration = matcher.calibrateThreshold(
            positiveTemplates: templates,
            negativeWindows: negativeTemplates.map(\.samples)
        )

        if let negativeMin = calibration.negativeMinDistance, negativeMin <= calibration.positiveMaxDistance {
            warnings.append("正样本和负样本距离重叠，容易误触发。")
        }

        let conflictDistance = nearestConflictDistance(templates: templates, profiles: existingProfiles)
        if let conflictDistance, conflictDistance < calibration.threshold * 1.2 {
            warnings.append("该动作和已有动作相似，建议提高严格度或重新录制。")
        }

        let averageTemplateQuality = templates.isEmpty
            ? 0
            : templates.map(\.qualityScore).reduce(0, +) / Double(templates.count)

        var score = averageTemplateQuality
        if templates.count == 1 {
            score -= 0.35
        } else if templates.count < 3 {
            score -= 0.18
        }

        if let negativeMin = calibration.negativeMinDistance {
            let separation = negativeMin - calibration.positiveMaxDistance
            if separation < 0.05 {
                score -= 0.25
            } else if separation < 0.15 {
                score -= 0.12
            }
        }

        if conflictDistance != nil {
            score -= 0.12
        }

        score = max(0, min(1, score))

        return GestureQualityReport(
            score: score,
            reliability: reliability(for: score),
            warnings: warnings,
            positiveMaxDistance: templates.count >= 2 ? calibration.positiveMaxDistance : nil,
            negativeMinDistance: calibration.negativeMinDistance,
            conflictDistance: conflictDistance
        )
    }

    private func reliability(for score: Double) -> GestureReliability {
        if score >= 0.75 {
            return .high
        }
        if score >= 0.45 {
            return .medium
        }
        return .low
    }

    private func nearestConflictDistance(
        templates: [MotionTemplate],
        profiles: [GestureProfile]
    ) -> Double? {
        let otherTemplates = profiles.flatMap(\.templates)
        guard !templates.isEmpty, !otherTemplates.isEmpty else { return nil }

        return templates
            .flatMap { template in otherTemplates.map { matcher.distance(template.samples, $0.samples) } }
            .min()
    }
}

public struct GestureProfileBuilder: Sendable {
    public var matcher: MotionTemplateMatcher
    public var evaluator: GestureQualityEvaluator
    public var signatureBuilder: GestureSignatureBuilder

    public init(
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        evaluator: GestureQualityEvaluator = GestureQualityEvaluator(),
        signatureBuilder: GestureSignatureBuilder = GestureSignatureBuilder()
    ) {
        self.matcher = matcher
        self.evaluator = evaluator
        self.signatureBuilder = signatureBuilder
    }

    public func makeProfile(
        name: String,
        kind: GestureKind,
        templates: [MotionTemplate],
        negativeTemplates: [MotionTemplate] = [],
        sound: SoundAsset? = nil,
        wearContext: WearContext? = nil,
        existingProfiles: [GestureProfile] = [],
        cooldownSeconds: Double = 0.8,
        strictness: Double = 0.5,
        createdAt: Date = Date()
    ) -> GestureProfile {
        let calibration = matcher.calibrateThreshold(
            positiveTemplates: templates,
            negativeWindows: negativeTemplates.map(\.samples)
        )
        let report = evaluator.evaluate(
            templates: templates,
            negativeTemplates: negativeTemplates,
            existingProfiles: existingProfiles
        )
        let signature = signatureBuilder.makeSignature(templates: templates)
        let thresholds = signatureBuilder.makeThresholds(
            signature: signature,
            templateCount: templates.count,
            strictness: strictness
        )

        return GestureProfile(
            name: name,
            kind: kind,
            templates: templates,
            negativeTemplates: negativeTemplates,
            acceptanceThreshold: calibration.threshold,
            marginThreshold: calibration.recommendedMarginThreshold,
            cooldownSeconds: cooldownSeconds,
            strictness: strictness,
            sound: sound,
            wearContext: wearContext,
            signature: signature,
            thresholds: thresholds,
            triggerPolicy: TriggerPolicy(
                cooldownSeconds: cooldownSeconds,
                playTiming: playTiming(for: signature.primaryKind),
                soundPolicy: .restartIfPlaying,
                allowRepeatedTrigger: true
            ),
            quality: report.quality,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func playTiming(for kind: MotionTokenKind) -> PlayTiming {
        switch kind {
        case .impulse:
            return .atImpulsePeak
        case .rotation:
            return .afterRotationCompleted
        case .oscillation:
            return .afterOscillationCountReached
        case .hold:
            return .afterHold
        case .sweep, .pause, .free:
            return .afterSegmentEnd
        }
    }
}

public struct GestureProfileArchive: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [GestureProfile]
    public var exportedAt: Date

    public init(schemaVersion: Int = 1, profiles: [GestureProfile], exportedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.exportedAt = exportedAt
    }
}

public struct GestureProfileCodec: Sendable {
    public init() {}

    public func encode(_ archive: GestureProfileArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    public func decode(_ data: Data) throws -> GestureProfileArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GestureProfileArchive.self, from: data)
    }
}
