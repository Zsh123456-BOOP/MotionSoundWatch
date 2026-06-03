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

public struct MotionRecordingValidator: Sendable {
    public var shortDurationHint: Double
    public var longDurationHint: Double
    public var minimumSamples: Int

    public init(
        shortDurationHint: Double = 0.25,
        longDurationHint: Double = 4.0,
        minimumSamples: Int = 12
    ) {
        self.shortDurationHint = shortDurationHint
        self.longDurationHint = longDurationHint
        self.minimumSamples = minimumSamples
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

    private func peakEnergy(_ samples: [MotionSample]) -> Double {
        samples.map { $0.userAcceleration.magnitude + 0.25 * $0.rotationRate.magnitude }.max() ?? 0
    }
}

public struct RecognitionCandidate: Equatable, Sendable {
    public var profile: GestureProfile
    public var distance: Double
    public var secondBestDistance: Double?
    public var margin: Double?
    public var confidence: Double
    public var templateID: UUID

    public var shouldTrigger: Bool {
        let passesDistance = distance <= profile.acceptanceThreshold
        let passesMargin = (margin ?? .infinity) >= profile.marginThreshold
        return passesDistance && passesMargin
    }
}

public struct ThresholdCalibration: Equatable, Sendable {
    public var threshold: Double
    public var positiveMaxDistance: Double
    public var negativeMinDistance: Double?
    public var margin: Double
    public var recommendedMarginThreshold: Double
}

public struct MotionTemplateMatcher: Sendable {
    public var targetSampleCount: Int
    public var sakoeChibaRadius: Int

    public init(targetSampleCount: Int = 48, sakoeChibaRadius: Int = 8) {
        self.targetSampleCount = targetSampleCount
        self.sakoeChibaRadius = sakoeChibaRadius
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
        let leftFrames = normalize(resample(lhs, targetCount: targetSampleCount))
        let rightFrames = normalize(resample(rhs, targetCount: targetSampleCount))
        return dynamicTimeWarping(leftFrames, rightFrames, radius: sakoeChibaRadius)
    }

    public func calibrateThreshold(
        positiveTemplates: [MotionTemplate],
        negativeWindows: [[MotionSample]] = [],
        paddingRatio: Double = 0.18
    ) -> ThresholdCalibration {
        guard positiveTemplates.count >= 2 else {
            return ThresholdCalibration(
                threshold: 0.30,
                positiveMaxDistance: 0,
                negativeMinDistance: nil,
                margin: 0.30,
                recommendedMarginThreshold: 0
            )
        }

        var positiveDistances: [Double] = []
        for i in positiveTemplates.indices {
            for j in positiveTemplates.indices where j > i {
                positiveDistances.append(distance(positiveTemplates[i].samples, positiveTemplates[j].samples))
            }
        }

        let positiveMax = positiveDistances.max() ?? 0.25
        let paddedPositive = max(positiveMax * (1 + paddingRatio), positiveMax + 0.05)
        let negativeMin = negativeWindows
            .flatMap { negative in positiveTemplates.map { distance($0.samples, negative) } }
            .min()

        let threshold: Double
        if let negativeMin {
            threshold = min(paddedPositive, max(positiveMax + 0.02, negativeMin * 0.72))
        } else {
            threshold = paddedPositive
        }

        return ThresholdCalibration(
            threshold: threshold,
            positiveMaxDistance: positiveMax,
            negativeMinDistance: negativeMin,
            margin: (negativeMin ?? threshold) - positiveMax,
            recommendedMarginThreshold: max(0, ((negativeMin ?? threshold) - positiveMax) * 0.35)
        )
    }

    private func bestTemplateDistance(
        profile: GestureProfile,
        candidateSamples: [MotionSample]
    ) -> (distance: Double, secondBestDistance: Double?, margin: Double?, templateID: UUID)? {
        let ranked = profile.templates
            .map { (distance($0.samples, candidateSamples), $0.id) }
            .sorted { $0.0 < $1.0 }

        guard let best = ranked.first else { return nil }
        let secondBestDistance = ranked.dropFirst().first?.0
        let margin = secondBestDistance.map { $0 - best.0 }
        return (distance: best.0, secondBestDistance: secondBestDistance, margin: margin, templateID: best.1)
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
            gravity: interpolateOptional(left.gravity, right.gravity, alpha: alpha)
        ))
    }

    return output
}

private func normalize(_ samples: [MotionSample]) -> [MotionFeatureFrame] {
    guard !samples.isEmpty else { return [] }

    let raw = samples.map {
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
    let scales = columns.map { values in
        max(values.map { abs($0) }.max() ?? 1, 0.001)
    }

    return raw.map { row in
        MotionFeatureFrame(values: row.indices.map { (row[$0] - means[$0]) / scales[$0] })
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
