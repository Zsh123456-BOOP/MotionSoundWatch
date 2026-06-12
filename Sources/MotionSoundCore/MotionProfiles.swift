import CryptoKit
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
        let calibrationReport = matcher.calibrationReport(
            positiveTemplates: templates,
            negativeWindows: negativeTemplates.map(\.samples)
        )
        warnings.append(contentsOf: calibrationReport.warnings)

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

/// 多样本一致性分析与异常样本检测。
/// 用于训练阶段：对同一动作的 3~5 次录制，评估彼此一致性、给出融合原型、
/// 并自动标记明显偏离的离群样本（"自动筛除异常样本"）。
public struct MotionTemplateConsistency: Equatable, Sendable {
    /// 0...1，越高越一致（基于成对 DTW 距离）。
    public var score: Double
    /// 成对距离中位数。
    public var medianDistance: Double
    /// 成对距离最大值。
    public var maxDistance: Double
    /// 被判定为离群的模板下标（相对传入数组）。
    public var outlierIndices: [Int]

    public init(score: Double, medianDistance: Double, maxDistance: Double, outlierIndices: [Int]) {
        self.score = score
        self.medianDistance = medianDistance
        self.maxDistance = maxDistance
        self.outlierIndices = outlierIndices
    }
}

public struct MotionTemplateFusion: Sendable {
    public var matcher: MotionTemplateMatcher
    /// 离群判定阈值：某样本到其余样本的平均距离超过 (中位数 * factor + floor) 即视为离群。
    public var outlierFactor: Double
    public var outlierFloor: Double

    public init(
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        outlierFactor: Double = 1.8,
        outlierFloor: Double = 0.12
    ) {
        self.matcher = matcher
        self.outlierFactor = outlierFactor
        self.outlierFloor = outlierFloor
    }

    /// 计算一致性与离群样本。少于 3 个样本时不做离群判定（样本太少不可靠）。
    public func consistency(of templates: [MotionTemplate]) -> MotionTemplateConsistency {
        guard templates.count >= 2 else {
            return MotionTemplateConsistency(score: templates.isEmpty ? 0 : 1, medianDistance: 0, maxDistance: 0, outlierIndices: [])
        }

        // 成对距离矩阵。
        var pairwise: [Double] = []
        var distanceMatrix = Array(repeating: Array(repeating: Double.infinity, count: templates.count), count: templates.count)
        for i in templates.indices {
            for j in templates.indices where j > i {
                let d = matcher.distance(templates[i].samples, templates[j].samples)
                pairwise.append(d)
                distanceMatrix[i][j] = d
                distanceMatrix[j][i] = d
            }
        }

        // 每个样本到"最近邻"的距离：离群样本没有近邻，对单个离群更鲁棒
        // （不会像平均距离那样被离群自身污染参考值）。
        let nearestNeighbor: [Double] = templates.indices.map { i in
            templates.indices
                .filter { $0 != i }
                .map { distanceMatrix[i][$0] }
                .min() ?? 0
        }

        let median = MotionTemplateFusion.median(pairwise)
        let maxDistance = pairwise.max() ?? 0
        // 一致性分数：距离越小越高。0.30 处约为 0.5 分。
        let score = max(0, min(1, 1 - median / 0.30 * 0.5))

        var outliers: [Int] = []
        if templates.count >= 3 {
            let nnMedian = MotionTemplateFusion.median(nearestNeighbor)
            let threshold = nnMedian * outlierFactor + outlierFloor
            for i in templates.indices where nearestNeighbor[i] > threshold {
                outliers.append(i)
            }
            // 安全阀：最多剔除不超过总数的 1/3，避免把整组判为离群。
            let maxRemovable = max(0, templates.count / 3)
            if outliers.count > maxRemovable {
                // 只保留偏离最严重的那些。
                outliers = outliers
                    .sorted { nearestNeighbor[$0] > nearestNeighbor[$1] }
                    .prefix(maxRemovable)
                    .sorted()
            }
        }

        return MotionTemplateConsistency(
            score: score,
            medianDistance: median,
            maxDistance: maxDistance,
            outlierIndices: outliers
        )
    }

    /// 时间对齐平均得到的融合原型（所有样本重采样到统一长度后逐帧平均）。
    /// 返回 nil 表示样本不足。融合原型可用于可视化、签名表征或未来的单原型匹配。
    public func fusedPrototype(
        from templates: [MotionTemplate],
        targetCount: Int = 48,
        label: String? = nil
    ) -> MotionTemplate? {
        let usable = templates.filter { $0.samples.count >= 2 }
        guard !usable.isEmpty else { return nil }
        guard usable.count > 1 else { return usable.first }

        let resampled = usable.map { resampleUniform($0.samples, count: targetCount) }
        let duration = usable.map(\.rawDuration).reduce(0, +) / Double(usable.count)

        var fused: [MotionSample] = []
        fused.reserveCapacity(targetCount)
        for frame in 0..<targetCount {
            var acc = MotionVector3(x: 0, y: 0, z: 0)
            var gyr = MotionVector3(x: 0, y: 0, z: 0)
            for series in resampled {
                acc = MotionVector3(x: acc.x + series[frame].userAcceleration.x,
                                    y: acc.y + series[frame].userAcceleration.y,
                                    z: acc.z + series[frame].userAcceleration.z)
                gyr = MotionVector3(x: gyr.x + series[frame].rotationRate.x,
                                    y: gyr.y + series[frame].rotationRate.y,
                                    z: gyr.z + series[frame].rotationRate.z)
            }
            let n = Double(resampled.count)
            let t = duration * Double(frame) / Double(targetCount - 1)
            fused.append(MotionSample(
                timestamp: t,
                userAcceleration: MotionVector3(x: acc.x / n, y: acc.y / n, z: acc.z / n),
                rotationRate: MotionVector3(x: gyr.x / n, y: gyr.y / n, z: gyr.z / n)
            ))
        }

        let features = MotionEnergyAnalyzer().features(for: fused)
        let avgQuality = usable.map(\.qualityScore).reduce(0, +) / Double(usable.count)
        return MotionTemplate(
            label: label ?? usable.first?.label ?? "fused",
            kind: usable.first?.kind ?? .burst,
            samples: fused,
            features: features,
            qualityScore: avgQuality
        )
    }

    private func resampleUniform(_ samples: [MotionSample], count: Int) -> [MotionSample] {
        guard samples.count > 1, count > 1,
              let first = samples.first, let last = samples.last else {
            return samples
        }
        let start = first.timestamp
        let span = max(last.timestamp - start, .leastNonzeroMagnitude)
        var output: [MotionSample] = []
        output.reserveCapacity(count)
        var src = 0
        for i in 0..<count {
            let t = start + span * Double(i) / Double(count - 1)
            while src < samples.count - 2, samples[src + 1].timestamp < t { src += 1 }
            let l = samples[src]
            let r = samples[min(src + 1, samples.count - 1)]
            let seg = max(r.timestamp - l.timestamp, .leastNonzeroMagnitude)
            let a = max(0, min(1, (t - l.timestamp) / seg))
            output.append(MotionSample(
                timestamp: t,
                userAcceleration: MotionVector3(
                    x: l.userAcceleration.x + (r.userAcceleration.x - l.userAcceleration.x) * a,
                    y: l.userAcceleration.y + (r.userAcceleration.y - l.userAcceleration.y) * a,
                    z: l.userAcceleration.z + (r.userAcceleration.z - l.userAcceleration.z) * a
                ),
                rotationRate: MotionVector3(
                    x: l.rotationRate.x + (r.rotationRate.x - l.rotationRate.x) * a,
                    y: l.rotationRate.y + (r.rotationRate.y - l.rotationRate.y) * a,
                    z: l.rotationRate.z + (r.rotationRate.z - l.rotationRate.z) * a
                )
            ))
        }
        return output
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

public struct GestureSampleCollectionPlan: Equatable, Sendable {
    public var acceptedCount: Int
    public var requiredCount: Int
    public var isReady: Bool
    public var needsMoreSamples: Bool
    public var hasHighDeviation: Bool
    public var qualityScore: Double
    public var message: String
    public var warnings: [String]
    /// 多样本一致性分数（0...1）。样本不足 2 个时为 nil。
    public var consistencyScore: Double?
    /// 被判定为离群的样本下标（相对已采纳样本顺序），建议用户删除重录。
    public var outlierIndices: [Int]

    public init(
        acceptedCount: Int,
        requiredCount: Int,
        isReady: Bool,
        needsMoreSamples: Bool,
        hasHighDeviation: Bool,
        qualityScore: Double,
        message: String,
        warnings: [String] = [],
        consistencyScore: Double? = nil,
        outlierIndices: [Int] = []
    ) {
        self.acceptedCount = acceptedCount
        self.requiredCount = requiredCount
        self.isReady = isReady
        self.needsMoreSamples = needsMoreSamples
        self.hasHighDeviation = hasHighDeviation
        self.qualityScore = qualityScore
        self.message = message
        self.warnings = warnings
        self.consistencyScore = consistencyScore
        self.outlierIndices = outlierIndices
    }
}

public struct GestureSampleCollectionPolicy: Sendable {
    public var minimumTemplateCount: Int
    public var highDeviationTemplateCount: Int
    public var highDistanceThreshold: Double
    public var highDurationRatioThreshold: Double
    public var evaluator: GestureQualityEvaluator
    public var matcher: MotionTemplateMatcher

    public var fusion: MotionTemplateFusion

    public init(
        minimumTemplateCount: Int = 5,
        highDeviationTemplateCount: Int = 5,
        highDistanceThreshold: Double = 0.26,
        highDurationRatioThreshold: Double = 2.4,
        evaluator: GestureQualityEvaluator = GestureQualityEvaluator(),
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        fusion: MotionTemplateFusion = MotionTemplateFusion()
    ) {
        self.minimumTemplateCount = minimumTemplateCount
        self.highDeviationTemplateCount = highDeviationTemplateCount
        self.highDistanceThreshold = highDistanceThreshold
        self.highDurationRatioThreshold = highDurationRatioThreshold
        self.evaluator = evaluator
        self.matcher = matcher
        self.fusion = fusion
    }

    public func plan(
        templates: [MotionTemplate],
        existingProfiles: [GestureProfile] = []
    ) -> GestureSampleCollectionPlan {
        let count = templates.count
        let report = evaluator.evaluate(
            templates: templates,
            negativeTemplates: [],
            existingProfiles: existingProfiles
        )
        let highDeviation = hasHighDeviation(templates)
        let required = max(minimumTemplateCount, highDeviation ? highDeviationTemplateCount : minimumTemplateCount)
        let ready = count >= required

        let consistency = templates.count >= 2 ? fusion.consistency(of: templates) : nil

        let message: String
        if count == 0 {
            message = "先录第 1 次动作。系统会学习 5 次录制里的自然差异。"
        } else if count < required {
            message = "已确认 \(count)/\(required) 次。继续录同一个动作。"
        } else {
            message = "已确认 \(count) 次录制，可以配置声音并保存。"
        }

        var warnings = report.warnings
        if let consistency, !consistency.outlierIndices.isEmpty {
            let positions = consistency.outlierIndices.map { String($0 + 1) }.joined(separator: "、")
            warnings.append("第 \(positions) 次录制和其余几次差异较大，建议删除重录。")
        }

        return GestureSampleCollectionPlan(
            acceptedCount: count,
            requiredCount: required,
            isReady: ready,
            needsMoreSamples: !ready,
            hasHighDeviation: highDeviation,
            qualityScore: report.score,
            message: message,
            warnings: warnings,
            consistencyScore: consistency?.score,
            outlierIndices: consistency?.outlierIndices ?? []
        )
    }

    private func hasHighDeviation(_ templates: [MotionTemplate]) -> Bool {
        guard templates.count >= minimumTemplateCount else {
            return false
        }

        let calibration = matcher.calibrateThreshold(positiveTemplates: templates)
        if calibration.positiveMaxDistance >= highDistanceThreshold {
            return true
        }

        let durations = templates.map(\.rawDuration).filter { $0 > 0 }
        if let shortest = durations.min(), let longest = durations.max(), shortest > 0,
           longest / shortest >= highDurationRatioThreshold {
            return true
        }

        let qualityScores = templates.map(\.qualityScore)
        if standardDeviation(qualityScores) >= 0.28 {
            return true
        }

        return false
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values
            .map { pow($0 - mean, 2) }
            .reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }
}

public struct GestureProfileBuilder: Sendable {
    public var matcher: MotionTemplateMatcher
    public var evaluator: GestureQualityEvaluator
    public var signatureBuilder: GestureSignatureBuilder
    public var variantBuilder: GestureProfileVariantBuilder

    public init(
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        evaluator: GestureQualityEvaluator = GestureQualityEvaluator(),
        signatureBuilder: GestureSignatureBuilder = GestureSignatureBuilder(),
        variantBuilder: GestureProfileVariantBuilder = GestureProfileVariantBuilder()
    ) {
        self.matcher = matcher
        self.evaluator = evaluator
        self.signatureBuilder = signatureBuilder
        self.variantBuilder = variantBuilder
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
        let calibrationReport = matcher.calibrationReport(
            positiveTemplates: templates,
            negativeWindows: negativeTemplates.map(\.samples)
        )
        let report = evaluator.evaluate(
            templates: templates,
            negativeTemplates: negativeTemplates,
            existingProfiles: existingProfiles
        )
        let signature = signatureBuilder.makeSignature(templates: templates)
        var thresholds = signatureBuilder.makeThresholds(
            signature: signature,
            templateCount: templates.count,
            strictness: max(strictness, calibrationReport.recommendedStrictness)
        )
        thresholds.triggerScore = max(thresholds.triggerScore, calibrationReport.triggerScore)
        thresholds.marginScore = max(thresholds.marginScore, calibrationReport.marginScore)
        let variants = variantBuilder.makeVariants(
            templates: templates,
            negativeTemplates: negativeTemplates,
            strictness: strictness,
            existingProfiles: existingProfiles
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
            signatureVariants: variants,
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
    public var libraryVersion: String?
    public var profiles: [GestureProfile]
    public var exportedAt: Date

    public init(
        schemaVersion: Int = 1,
        libraryVersion: String? = nil,
        profiles: [GestureProfile],
        exportedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.libraryVersion = libraryVersion
        self.profiles = profiles
        self.exportedAt = exportedAt
    }
}

public struct ProfileSyncManifest: Codable, Equatable, Sendable {
    public var transactionID: UUID
    public var libraryVersion: String
    public var profileCount: Int
    public var profileFileName: String
    public var profileChecksum: String
    public var audioChecksumsByFileName: [String: String]
    public var sentAt: Date

    public init(
        transactionID: UUID = UUID(),
        libraryVersion: String,
        profileCount: Int,
        profileFileName: String,
        profileChecksum: String,
        audioChecksumsByFileName: [String: String] = [:],
        sentAt: Date = Date()
    ) {
        self.transactionID = transactionID
        self.libraryVersion = libraryVersion
        self.profileCount = profileCount
        self.profileFileName = profileFileName
        self.profileChecksum = profileChecksum
        self.audioChecksumsByFileName = audioChecksumsByFileName
        self.sentAt = sentAt
    }
}

public struct ProfileSyncAck: Codable, Equatable, Sendable {
    public var transactionID: UUID
    public var libraryVersion: String
    public var applied: Bool
    public var profileCount: Int
    public var missingAudioFileNames: [String]
    public var reason: String?
    public var sentAt: Date

    public init(
        transactionID: UUID,
        libraryVersion: String,
        applied: Bool,
        profileCount: Int,
        missingAudioFileNames: [String] = [],
        reason: String? = nil,
        sentAt: Date = Date()
    ) {
        self.transactionID = transactionID
        self.libraryVersion = libraryVersion
        self.applied = applied
        self.profileCount = profileCount
        self.missingAudioFileNames = missingAudioFileNames
        self.reason = reason
        self.sentAt = sentAt
    }
}

/// WatchConnectivity 消息里 Codable payload 的统一编解码（ISO8601 日期）。
public enum MotionSoundSyncCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// 当前启用动作的同步状态。revision 单调递增，双端 last-writer-wins：
/// 收到 revision 更小（或相等但 updatedAt 更早）的状态一律忽略，防止
/// userInfo / applicationContext 乱序重放旧选择。
public struct ActiveProfileSyncState: Codable, Equatable, Sendable {
    public var revision: Int
    public var profileID: UUID?
    public var profileName: String?
    public var updatedAt: Date
    /// 发起方："phone" / "watch"
    public var origin: String

    public init(
        revision: Int,
        profileID: UUID?,
        profileName: String?,
        updatedAt: Date = Date(),
        origin: String
    ) {
        self.revision = revision
        self.profileID = profileID
        self.profileName = profileName
        self.updatedAt = updatedAt
        self.origin = origin
    }

    /// state 是否应覆盖 current（revision 优先，updatedAt 兜底）。
    public func supersedes(_ current: ActiveProfileSyncState?) -> Bool {
        guard let current else { return true }
        if revision != current.revision {
            return revision > current.revision
        }
        return updatedAt > current.updatedAt
    }
}

/// Watch 对激活命令的回执。pending=true 表示命令已收到、
/// 但目标动作尚未出现在已同步的动作库中（挂起等待库加载后重放）。
public struct ActiveProfileSyncAck: Codable, Equatable, Sendable {
    public var revision: Int
    public var profileID: UUID?
    public var profileName: String?
    public var applied: Bool
    public var pending: Bool
    public var reason: String?
    public var sentAt: Date

    public init(
        revision: Int,
        profileID: UUID?,
        profileName: String?,
        applied: Bool,
        pending: Bool = false,
        reason: String? = nil,
        sentAt: Date = Date()
    ) {
        self.revision = revision
        self.profileID = profileID
        self.profileName = profileName
        self.applied = applied
        self.pending = pending
        self.reason = reason
        self.sentAt = sentAt
    }
}

public enum GestureProfileLibraryVersion {
    public static func make(profiles: [GestureProfile]) -> String {
        let payload = canonicalPayload(for: profiles)
        let digest = SHA256.hash(data: Data(payload.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        return "lib-\(digest)"
    }

    public static func canonicalPayload(for profiles: [GestureProfile]) -> String {
        profiles
            .sorted { lhs, rhs in
                if lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map(canonicalProfile)
            .joined(separator: "\n")
    }

    private static func canonicalProfile(_ profile: GestureProfile) -> String {
        var fields: [String] = [
            "profile",
            profile.id.uuidString,
            profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
            profile.kind.rawValue,
            number(profile.acceptanceThreshold),
            number(profile.marginThreshold),
            number(profile.cooldownSeconds),
            number(profile.strictness),
            profile.triggerTiming.rawValue,
            profile.customDelayMilliseconds.map(String.init) ?? "",
            canonicalSound(profile.sound),
            (profile.soundSequence ?? []).map(canonicalSound).joined(separator: ","),
            canonicalWearContext(profile.wearContext),
            canonicalThresholds(profile.thresholds),
            canonicalTriggerPolicy(profile.triggerPolicy),
            "templates[\(profile.templates.count)]",
            profile.templates.map(canonicalTemplate).sorted().joined(separator: "\n"),
            "negativeTemplates[\(profile.negativeTemplates.count)]",
            profile.negativeTemplates.map(canonicalTemplate).sorted().joined(separator: "\n"),
        ]
        if let minAngle = profile.signature?.rotation?.totalAngleRadians {
            fields.append("rotationTotalAngle=\(number(minAngle))")
        }
        if let primaryKind = profile.signature?.primaryKind {
            fields.append("primaryKind=\(primaryKind.rawValue)")
        }
        return fields.joined(separator: "|")
    }

    private static func canonicalTemplate(_ template: MotionTemplate) -> String {
        [
            "template",
            template.label.trimmingCharacters(in: .whitespacesAndNewlines),
            template.kind.rawValue,
            number(template.rawDuration),
            number(template.sampleRate),
            number(template.qualityScore),
            canonicalFeatures(template.features),
            "samples[\(template.samples.count)]",
            template.samples.map(canonicalSample).joined(separator: ";"),
        ].joined(separator: "|")
    }

    private static func canonicalSample(_ sample: MotionSample) -> String {
        [
            number(sample.timestamp),
            canonicalVector(sample.userAcceleration),
            canonicalVector(sample.rotationRate),
            sample.gravity.map(canonicalVector) ?? "",
            sample.attitude.map(canonicalQuaternion) ?? "",
        ].joined(separator: ",")
    }

    private static func canonicalFeatures(_ features: GestureFeatures?) -> String {
        guard let features else { return "" }
        return [
            number(features.duration),
            number(features.peakAcceleration),
            number(features.peakRotationRate),
            number(features.peakJerk),
            number(features.meanEnergy),
            String(features.dominantAxis),
            features.energyShape.map(number).joined(separator: ","),
        ].joined(separator: ":")
    }

    private static func canonicalSound(_ sound: SoundAsset?) -> String {
        guard let sound else { return "" }
        return [
            sound.fileName,
            number(sound.duration),
            number(Double(sound.volume)),
            sound.checksum ?? "",
        ].joined(separator: ":")
    }

    private static func canonicalWearContext(_ context: WearContext?) -> String {
        guard let context else { return "" }
        return [
            context.wristLocation,
            context.crownOrientation,
            context.watchModel ?? "",
            context.osVersion ?? "",
        ].joined(separator: ":")
    }

    private static func canonicalThresholds(_ thresholds: ThresholdProfile?) -> String {
        guard let thresholds else { return "" }
        return [
            number(thresholds.triggerScore),
            number(thresholds.rejectScore),
            number(thresholds.marginScore),
            thresholds.minEnergy.map(number) ?? "",
            thresholds.minAngle.map(number) ?? "",
            thresholds.minOscillationCount.map(number) ?? "",
            thresholds.minHoldDuration.map(number) ?? "",
            number(thresholds.strictness),
        ].joined(separator: ":")
    }

    private static func canonicalTriggerPolicy(_ policy: TriggerPolicy?) -> String {
        guard let policy else { return "" }
        return [
            number(policy.cooldownSeconds),
            policy.playTiming.rawValue,
            policy.soundPolicy.rawValue,
            policy.allowRepeatedTrigger ? "1" : "0",
        ].joined(separator: ":")
    }

    private static func canonicalVector(_ vector: MotionVector3) -> String {
        "\(number(vector.x)):\(number(vector.y)):\(number(vector.z))"
    }

    private static func canonicalQuaternion(_ quaternion: MotionQuaternion) -> String {
        "\(number(quaternion.x)):\(number(quaternion.y)):\(number(quaternion.z)):\(number(quaternion.w))"
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", value)
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
        let archive = try decoder.decode(GestureProfileArchive.self, from: data)
        return GestureProfileArchive(
            schemaVersion: archive.schemaVersion,
            libraryVersion: archive.libraryVersion,
            profiles: archive.profiles.map(upgradeProfileIfNeeded),
            exportedAt: archive.exportedAt
        )
    }

    private func upgradeProfileIfNeeded(_ profile: GestureProfile) -> GestureProfile {
        guard !profile.templates.isEmpty else {
            return profile
        }

        let builder = GestureSignatureBuilder()
        let variantBuilder = GestureProfileVariantBuilder()
        let rebuiltSignature = builder.makeSignature(templates: profile.templates)
        var upgraded = profile
        if var signature = upgraded.signature {
            if signature.stages == nil || signature.stages?.isEmpty == true {
                signature.stages = rebuiltSignature.stages
            }
            if signature.pose == nil {
                signature.pose = rebuiltSignature.pose
            }
            upgraded.signature = signature
        } else {
            upgraded.signature = rebuiltSignature
        }

        let inferredKind = Self.inferredKind(from: upgraded.signature, fallback: upgraded.kind)
        let kindChanged = upgraded.kind != inferredKind
        if kindChanged {
            upgraded.kind = inferredKind
        }

        if (upgraded.thresholds == nil || kindChanged), let signature = upgraded.signature {
            upgraded.thresholds = builder.makeThresholds(
                signature: signature,
                templateCount: upgraded.templates.count,
                strictness: upgraded.strictness
            )
        }
        if upgraded.signatureVariants == nil || upgraded.signatureVariants?.isEmpty == true || kindChanged {
            upgraded.signatureVariants = variantBuilder.makeVariants(
                templates: upgraded.templates,
                negativeTemplates: upgraded.negativeTemplates,
                strictness: upgraded.strictness
            )
        }
        return upgraded
    }

    private static func inferredKind(from signature: GestureSignature?, fallback: GestureKind) -> GestureKind {
        guard fallback != .combo, let primaryKind = signature?.primaryKind else {
            return fallback
        }
        switch primaryKind {
        case .impulse, .sweep:
            return .burst
        case .rotation, .oscillation:
            return .sequence
        case .hold:
            return .posture
        case .pause, .free:
            return fallback
        }
    }
}
