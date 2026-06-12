import Foundation

public enum MotionTokenKind: String, Codable, Equatable, Sendable {
    case impulse
    case rotation
    case oscillation
    case hold
    case sweep
    case pause
    case free
}

public enum RejectReason: String, Codable, Equatable, Sendable {
    case noCandidate
    case segmentTooShort
    case segmentTooLong
    case lowEnergy
    case typeMismatch
    case impulsePeakTooWeak
    case impulseDirectionMismatch
    case rotationAngleTooSmall
    case rotationDirectionMismatch
    case rotationAxisUnstable
    case oscillationCountTooLow
    case oscillationNotPeriodic
    case holdNotStable
    case holdTooShort
    case scoreBelowThreshold
    case marginTooSmall
    case cooldownActive
    case audioMissing
    case noActiveProfile
    case trajectoryDistanceTooHigh
    case poseMismatch
    case stageMismatch
}

public enum RecognitionMode: String, Codable, Equatable, Sendable {
    case allProfiles
    case activeProfiles
}

public enum TrimStrategy: String, Codable, Sendable {
    case impulsePeakWindow
    case rotationAngleWindow
    case oscillationCycleWindow
    case holdStableWindow
    case fullActiveWindow
}

public struct TokenizerCalibration: Codable, Equatable, Sendable {
    public var impulsePeakAccP20: Double?
    public var impulsePeakGyroP20: Double?
    public var rotationAngleP20: Double?
    public var rotationAxisStabilityP20: Double?
    public var oscillationCountP20: Double?
    public var periodicityP20: Double?
    public var holdStabilityP20: Double?

    public init(
        impulsePeakAccP20: Double? = nil,
        impulsePeakGyroP20: Double? = nil,
        rotationAngleP20: Double? = nil,
        rotationAxisStabilityP20: Double? = nil,
        oscillationCountP20: Double? = nil,
        periodicityP20: Double? = nil,
        holdStabilityP20: Double? = nil
    ) {
        self.impulsePeakAccP20 = impulsePeakAccP20
        self.impulsePeakGyroP20 = impulsePeakGyroP20
        self.rotationAngleP20 = rotationAngleP20
        self.rotationAxisStabilityP20 = rotationAxisStabilityP20
        self.oscillationCountP20 = oscillationCountP20
        self.periodicityP20 = periodicityP20
        self.holdStabilityP20 = holdStabilityP20
    }
}

public struct DominantAxisEstimate: Codable, Equatable, Sendable {
    public var axis: MotionVector3
    public var signedAngle: Double
    public var absoluteAngle: Double
    public var stability: Double

    public init(axis: MotionVector3, signedAngle: Double, absoluteAngle: Double, stability: Double) {
        self.axis = axis
        self.signedAngle = signedAngle
        self.absoluteAngle = absoluteAngle
        self.stability = stability
    }
}

public struct RecognitionFusionPolicy: Codable, Equatable, Sendable {
    public var trajectoryWeight: Double
    public var semanticWeight: Double
    public var stageWeight: Double
    public var poseWeight: Double
    public var maxSoftDistanceRatio: Double
    public var requireHardVetoPass: Bool

    public init(
        trajectoryWeight: Double = 0.52,
        semanticWeight: Double = 0.26,
        stageWeight: Double = 0.10,
        poseWeight: Double = 0.10,
        maxSoftDistanceRatio: Double = 1.30,
        requireHardVetoPass: Bool = true
    ) {
        self.trajectoryWeight = trajectoryWeight
        self.semanticWeight = semanticWeight
        self.stageWeight = stageWeight
        self.poseWeight = poseWeight
        self.maxSoftDistanceRatio = maxSoftDistanceRatio
        self.requireHardVetoPass = requireHardVetoPass
    }
}

public struct ActiveRecognitionSelection: Codable, Equatable, Sendable {
    public var mode: RecognitionMode
    public var activeProfileIDs: Set<UUID>

    public init(mode: RecognitionMode = .activeProfiles, activeProfileIDs: Set<UUID> = []) {
        self.mode = mode
        self.activeProfileIDs = activeProfileIDs
    }

    public static var inactive: ActiveRecognitionSelection {
        ActiveRecognitionSelection(mode: .activeProfiles, activeProfileIDs: [])
    }

    /// 显式 opt-in 的全库匹配模式，仅供测试、CLI 与离线评估使用。
    /// 产品运行时必须使用 activeProfiles 模式（用户必须先选择当前动作）。
    public static var allProfiles: ActiveRecognitionSelection {
        ActiveRecognitionSelection(mode: .allProfiles, activeProfileIDs: [])
    }
}

public enum PlayTiming: String, Codable, Equatable, Sendable {
    case atImpulsePeak
    case afterRotationCompleted
    case afterOscillationCountReached
    case afterHold
    case afterComboCompleted
    case afterSegmentEnd
}

public enum SoundPlayPolicy: String, Codable, Equatable, Sendable {
    case restartIfPlaying
    case ignoreIfPlaying
    case overlapAllowed
    case queueSequence
}

public struct GestureSampleFeatures: Codable, Equatable, Sendable {
    public var duration: Double
    public var peakAcc: Double
    public var peakGyro: Double
    public var peakJerk: Double
    public var meanAcc: Double
    public var meanGyro: Double
    public var integratedRotationAngle: Double
    public var signedRotationAngle: Double
    public var dominantRotationAxis: MotionVector3
    public var rotationAxisStability: Double
    public var oscillationCount: Double
    public var zeroCrossingCount: Int
    public var periodicityScore: Double
    public var holdDuration: Double
    public var holdStability: Double
    public var directionalityScore: Double
    public var numberOfBursts: Int

    public var rotationDirectionConsistency: Double {
        guard integratedRotationAngle > 0.0001 else { return 0 }
        return min(1, abs(signedRotationAngle) / integratedRotationAngle)
    }

    public init(
        duration: Double,
        peakAcc: Double,
        peakGyro: Double,
        peakJerk: Double,
        meanAcc: Double,
        meanGyro: Double,
        integratedRotationAngle: Double,
        signedRotationAngle: Double,
        dominantRotationAxis: MotionVector3,
        rotationAxisStability: Double,
        oscillationCount: Double,
        zeroCrossingCount: Int,
        periodicityScore: Double,
        holdDuration: Double,
        holdStability: Double,
        directionalityScore: Double,
        numberOfBursts: Int
    ) {
        self.duration = duration
        self.peakAcc = peakAcc
        self.peakGyro = peakGyro
        self.peakJerk = peakJerk
        self.meanAcc = meanAcc
        self.meanGyro = meanGyro
        self.integratedRotationAngle = integratedRotationAngle
        self.signedRotationAngle = signedRotationAngle
        self.dominantRotationAxis = dominantRotationAxis
        self.rotationAxisStability = rotationAxisStability
        self.oscillationCount = oscillationCount
        self.zeroCrossingCount = zeroCrossingCount
        self.periodicityScore = periodicityScore
        self.holdDuration = holdDuration
        self.holdStability = holdStability
        self.directionalityScore = directionalityScore
        self.numberOfBursts = numberOfBursts
    }
}

public struct MotionToken: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MotionTokenKind
    public var startTime: Double
    public var endTime: Double
    public var duration: Double
    public var mainAxis: MotionVector3
    public var direction: Double
    public var magnitude: Double
    public var confidence: Double
    public var peakAcc: Double?
    public var peakGyro: Double?
    public var integratedAngle: Double?
    public var oscillationCount: Double?
    public var holdStability: Double?

    public init(
        id: UUID = UUID(),
        kind: MotionTokenKind,
        startTime: Double,
        endTime: Double,
        duration: Double,
        mainAxis: MotionVector3,
        direction: Double,
        magnitude: Double,
        confidence: Double,
        peakAcc: Double? = nil,
        peakGyro: Double? = nil,
        integratedAngle: Double? = nil,
        oscillationCount: Double? = nil,
        holdStability: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.mainAxis = mainAxis
        self.direction = direction
        self.magnitude = magnitude
        self.confidence = confidence
        self.peakAcc = peakAcc
        self.peakGyro = peakGyro
        self.integratedAngle = integratedAngle
        self.oscillationCount = oscillationCount
        self.holdStability = holdStability
    }
}

public struct ImpulseSignature: Codable, Equatable, Sendable {
    public var mainAxis: MotionVector3
    public var direction: Double
    public var peakAcc: Double
    public var peakGyro: Double
    public var duration: Double
    public var reboundRatio: Double
}

public struct RotationSignature: Codable, Equatable, Sendable {
    public var axis: MotionVector3
    public var direction: Double
    public var totalAngleRadians: Double
    public var circleCount: Double
    public var duration: Double
    public var axisStability: Double
    public var angularSpeedMean: Double
    public var angularSpeedStd: Double
}

public struct OscillationSignature: Codable, Equatable, Sendable {
    public var axis: MotionVector3
    public var count: Double
    public var duration: Double
    public var periodicityScore: Double
    public var magnitude: Double
}

public struct HoldSignature: Codable, Equatable, Sendable {
    public var duration: Double
    public var stability: Double
    public var meanGyro: Double
}

public struct NormalizedMotionTemplate: Codable, Equatable, Sendable {
    public var templateID: UUID
    public var samples: [MotionSample]
}

public struct MotionTokenPattern: Codable, Equatable, Sendable {
    public var kind: MotionTokenKind
    public var minDuration: Double
    public var maxDuration: Double
    public var expectedMagnitude: Double

    public init(kind: MotionTokenKind, minDuration: Double, maxDuration: Double, expectedMagnitude: Double) {
        self.kind = kind
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.expectedMagnitude = expectedMagnitude
    }
}

public struct MotionStageSignature: Codable, Equatable, Sendable {
    public var kind: MotionTokenKind
    public var minDuration: Double
    public var maxDuration: Double
    public var expectedMagnitude: Double

    public init(kind: MotionTokenKind, minDuration: Double, maxDuration: Double, expectedMagnitude: Double) {
        self.kind = kind
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.expectedMagnitude = expectedMagnitude
    }
}

public struct MotionPoseSignature: Codable, Equatable, Sendable {
    public var startGravity: MotionVector3
    public var endGravity: MotionVector3
    public var gravityDelta: MotionVector3
    public var terminalHoldDuration: Double
    public var confidence: Double

    public init(
        startGravity: MotionVector3,
        endGravity: MotionVector3,
        gravityDelta: MotionVector3,
        terminalHoldDuration: Double,
        confidence: Double
    ) {
        self.startGravity = startGravity
        self.endGravity = endGravity
        self.gravityDelta = gravityDelta
        self.terminalHoldDuration = terminalHoldDuration
        self.confidence = confidence
    }
}

public struct GestureSignature: Codable, Equatable, Sendable {
    public var primaryKind: MotionTokenKind
    public var secondaryKinds: [MotionTokenKind]
    public var tokenPatterns: [MotionTokenPattern]
    public var tokenizerCalibration: TokenizerCalibration?
    public var fusionPolicy: RecognitionFusionPolicy?
    public var stages: [MotionStageSignature]?
    public var pose: MotionPoseSignature?
    public var impulse: ImpulseSignature?
    public var rotation: RotationSignature?
    public var oscillation: OscillationSignature?
    public var hold: HoldSignature?
    public var fallbackTemplates: [NormalizedMotionTemplate]

    public init(
        primaryKind: MotionTokenKind,
        secondaryKinds: [MotionTokenKind] = [],
        tokenPatterns: [MotionTokenPattern] = [],
        tokenizerCalibration: TokenizerCalibration? = nil,
        fusionPolicy: RecognitionFusionPolicy? = nil,
        stages: [MotionStageSignature]? = nil,
        pose: MotionPoseSignature? = nil,
        impulse: ImpulseSignature? = nil,
        rotation: RotationSignature? = nil,
        oscillation: OscillationSignature? = nil,
        hold: HoldSignature? = nil,
        fallbackTemplates: [NormalizedMotionTemplate] = []
    ) {
        self.primaryKind = primaryKind
        self.secondaryKinds = secondaryKinds
        self.tokenPatterns = tokenPatterns
        self.tokenizerCalibration = tokenizerCalibration
        self.fusionPolicy = fusionPolicy
        self.stages = stages
        self.pose = pose
        self.impulse = impulse
        self.rotation = rotation
        self.oscillation = oscillation
        self.hold = hold
        self.fallbackTemplates = fallbackTemplates
    }
}

public struct GestureProfileVariant: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var templateIDs: [UUID]
    public var signature: GestureSignature
    public var thresholds: ThresholdProfile
    public var acceptanceThreshold: Double
    public var marginThreshold: Double
    public var quality: GestureQuality

    public init(
        id: UUID = UUID(),
        label: String,
        templateIDs: [UUID],
        signature: GestureSignature,
        thresholds: ThresholdProfile,
        acceptanceThreshold: Double,
        marginThreshold: Double,
        quality: GestureQuality
    ) {
        self.id = id
        self.label = label
        self.templateIDs = templateIDs
        self.signature = signature
        self.thresholds = thresholds
        self.acceptanceThreshold = acceptanceThreshold
        self.marginThreshold = marginThreshold
        self.quality = quality
    }
}

public struct ThresholdProfile: Codable, Equatable, Sendable {
    public var triggerScore: Double
    public var rejectScore: Double
    public var marginScore: Double
    public var minEnergy: Double?
    public var minAngle: Double?
    public var minOscillationCount: Double?
    public var minHoldDuration: Double?
    public var strictness: Double
    public var fusionPolicy: RecognitionFusionPolicy?

    public init(
        triggerScore: Double = 0.68,
        rejectScore: Double = 0.45,
        marginScore: Double = 0.06,
        minEnergy: Double? = nil,
        minAngle: Double? = nil,
        minOscillationCount: Double? = nil,
        minHoldDuration: Double? = nil,
        strictness: Double = 0.5,
        fusionPolicy: RecognitionFusionPolicy? = nil
    ) {
        self.triggerScore = triggerScore
        self.rejectScore = rejectScore
        self.marginScore = marginScore
        self.minEnergy = minEnergy
        self.minAngle = minAngle
        self.minOscillationCount = minOscillationCount
        self.minHoldDuration = minHoldDuration
        self.strictness = strictness
        self.fusionPolicy = fusionPolicy
    }
}

public struct TriggerPolicy: Codable, Equatable, Sendable {
    public var cooldownSeconds: Double
    public var playTiming: PlayTiming
    public var soundPolicy: SoundPlayPolicy
    public var allowRepeatedTrigger: Bool

    public init(
        cooldownSeconds: Double = 0.8,
        playTiming: PlayTiming = .afterSegmentEnd,
        soundPolicy: SoundPlayPolicy = .restartIfPlaying,
        allowRepeatedTrigger: Bool = true
    ) {
        self.cooldownSeconds = cooldownSeconds
        self.playTiming = playTiming
        self.soundPolicy = soundPolicy
        self.allowRepeatedTrigger = allowRepeatedTrigger
    }
}

public struct CandidateRecognitionReport: Codable, Equatable, Sendable {
    public var profileID: UUID
    public var profileName: String
    public var variantID: UUID?
    public var variantLabel: String?
    public var recognizerKind: MotionTokenKind
    public var score: Double
    public var threshold: Double
    public var margin: Double?
    public var shouldTrigger: Bool
    public var rejectReason: RejectReason?

    public init(
        profileID: UUID,
        profileName: String,
        variantID: UUID? = nil,
        variantLabel: String? = nil,
        recognizerKind: MotionTokenKind,
        score: Double,
        threshold: Double,
        margin: Double? = nil,
        shouldTrigger: Bool,
        rejectReason: RejectReason? = nil
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.variantID = variantID
        self.variantLabel = variantLabel
        self.recognizerKind = recognizerKind
        self.score = score
        self.threshold = threshold
        self.margin = margin
        self.shouldTrigger = shouldTrigger
        self.rejectReason = rejectReason
    }
}

public struct MotionFeatureExtractor: Sendable {
    public var energyAnalyzer: MotionEnergyAnalyzer
    /// 语义特征提取前的低通滤波。零交叉计数、旋转轴稳定度对高频噪声极敏感，
    /// 去噪后 oscillation / rotation 的判别更稳定，减少日常抖动被误判为周期动作。
    public var lowPassFilter: MotionLowPassFilter

    public init(
        energyAnalyzer: MotionEnergyAnalyzer = MotionEnergyAnalyzer(),
        lowPassFilter: MotionLowPassFilter = MotionLowPassFilter()
    ) {
        self.energyAnalyzer = energyAnalyzer
        self.lowPassFilter = lowPassFilter
    }

    public func extract(_ rawSamples: [MotionSample]) -> GestureSampleFeatures {
        let samples = lowPassFilter.filtered(rawSamples)
        let frames = energyAnalyzer.frames(for: samples)
        guard samples.count >= 2, !frames.isEmpty else {
            return GestureSampleFeatures(
                duration: 0,
                peakAcc: 0,
                peakGyro: 0,
                peakJerk: 0,
                meanAcc: 0,
                meanGyro: 0,
                integratedRotationAngle: 0,
                signedRotationAngle: 0,
                dominantRotationAxis: MotionVector3(x: 1, y: 0, z: 0),
                rotationAxisStability: 0,
                oscillationCount: 0,
                zeroCrossingCount: 0,
                periodicityScore: 0,
                holdDuration: 0,
                holdStability: 0,
                directionalityScore: 0,
                numberOfBursts: 0
            )
        }

        let duration = max(0, samples.last!.timestamp - samples.first!.timestamp)
        let peakAcc = frames.map(\.accelerationMagnitude).max() ?? 0
        let peakGyro = frames.map(\.rotationMagnitude).max() ?? 0
        let peakJerk = frames.map(\.jerkMagnitude).max() ?? 0
        let meanAcc = frames.map(\.accelerationMagnitude).reduce(0.0, +) / Double(frames.count)
        let meanGyro = frames.map(\.rotationMagnitude).reduce(0.0, +) / Double(frames.count)

        let axisData = dominantRotationAxis(samples)
        let projectedGyro = samples.map { dot($0.rotationRate, axisData.axis) }
        let integratedSignedAngle = axisData.signedAngle
        let integratedAbsAngle = axisData.absoluteAngle
        let zeroCrossings = zeroCrossingCount(projectedGyro, deadband: max(0.04, peakGyro * 0.08))
        let oscillationCount = Double(zeroCrossings) / 2.0
        let periodicity = periodicityScore(projectedGyro, zeroCrossings: zeroCrossings)
        let holdStability = holdStability(samples)
        let holdDuration = holdStability >= 0.72 ? duration : 0
        let directionality = directionalityScore(samples)
        let burstCount = numberOfBursts(frames)

        return GestureSampleFeatures(
            duration: duration,
            peakAcc: peakAcc,
            peakGyro: peakGyro,
            peakJerk: peakJerk,
            meanAcc: meanAcc,
            meanGyro: meanGyro,
            integratedRotationAngle: integratedAbsAngle,
            signedRotationAngle: integratedSignedAngle,
            dominantRotationAxis: axisData.axis,
            rotationAxisStability: axisData.stability,
            oscillationCount: oscillationCount,
            zeroCrossingCount: zeroCrossings,
            periodicityScore: periodicity,
            holdDuration: holdDuration,
            holdStability: holdStability,
            directionalityScore: directionality,
            numberOfBursts: burstCount
        )
    }

    public func dominantAxisEstimate(_ samples: [MotionSample]) -> DominantAxisEstimate {
        dominantRotationAxis(samples)
    }

    private func dominantRotationAxis(_ samples: [MotionSample]) -> DominantAxisEstimate {
        guard samples.count >= 2 else {
            return DominantAxisEstimate(
                axis: MotionVector3(x: 1, y: 0, z: 0),
                signedAngle: 0,
                absoluteAngle: 0,
                stability: 0
            )
        }

        var totalGyroEnergy = 0.0
        for sample in samples {
            let magnitude = sample.rotationRate.magnitude
            totalGyroEnergy += magnitude * magnitude
        }

        var axis = principalGyroAxis(samples)
        if axis.magnitude < 0.001 {
            axis = discreteFallbackAxis(samples)
        }

        let projected = samples.map { dot($0.rotationRate, axis) }
        let signedAngle = integrate(projected, samples: samples, absolute: false)
        if signedAngle < 0 {
            axis = MotionVector3(x: -axis.x, y: -axis.y, z: -axis.z)
        }
        let orientedProjected = samples.map { dot($0.rotationRate, axis) }
        let orientedSignedAngle = integrate(orientedProjected, samples: samples, absolute: false)
        let absoluteAngle = integrate(orientedProjected, samples: samples, absolute: true)
        let projectionEnergy = orientedProjected.map { $0 * $0 }.reduce(0.0, +)
        let stability = totalGyroEnergy > 0 ? min(1, projectionEnergy / totalGyroEnergy) : 0
        return DominantAxisEstimate(
            axis: axis,
            signedAngle: orientedSignedAngle,
            absoluteAngle: absoluteAngle,
            stability: stability
        )
    }

    private func principalGyroAxis(_ samples: [MotionSample]) -> MotionVector3 {
        var xx = 0.0, xy = 0.0, xz = 0.0
        var yy = 0.0, yz = 0.0, zz = 0.0
        for sample in samples {
            let g = sample.rotationRate
            xx += g.x * g.x
            xy += g.x * g.y
            xz += g.x * g.z
            yy += g.y * g.y
            yz += g.y * g.z
            zz += g.z * g.z
        }

        var axis = discreteFallbackAxis(samples)
        for _ in 0..<8 {
            let next = MotionVector3(
                x: xx * axis.x + xy * axis.y + xz * axis.z,
                y: xy * axis.x + yy * axis.y + yz * axis.z,
                z: xz * axis.x + yz * axis.y + zz * axis.z
            )
            axis = normalized(next)
            if axis.magnitude < 0.001 { break }
        }
        return axis
    }

    private func discreteFallbackAxis(_ samples: [MotionSample]) -> MotionVector3 {
        let totals = [
            samples.map { abs($0.rotationRate.x) }.reduce(0.0, +),
            samples.map { abs($0.rotationRate.y) }.reduce(0.0, +),
            samples.map { abs($0.rotationRate.z) }.reduce(0.0, +),
        ]
        let maxIndex = totals.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let sign = samples.map { sample in
            switch maxIndex {
            case 0: return sample.rotationRate.x
            case 1: return sample.rotationRate.y
            default: return sample.rotationRate.z
            }
        }.reduce(0.0, +) >= 0 ? 1.0 : -1.0
        switch maxIndex {
        case 0: return MotionVector3(x: sign, y: 0, z: 0)
        case 1: return MotionVector3(x: 0, y: sign, z: 0)
        default: return MotionVector3(x: 0, y: 0, z: sign)
        }
    }

    private func integrate(_ values: [Double], samples: [MotionSample], absolute: Bool) -> Double {
        guard values.count == samples.count, samples.count > 1 else { return 0 }
        var output = 0.0
        for index in 1..<samples.count {
            let dt = max(0, samples[index].timestamp - samples[index - 1].timestamp)
            let value = (values[index] + values[index - 1]) * 0.5
            output += (absolute ? abs(value) : value) * dt
        }
        return output
    }

    private func normalized(_ vector: MotionVector3) -> MotionVector3 {
        let magnitude = vector.magnitude
        guard magnitude >= 0.001 else { return MotionVector3(x: 0, y: 0, z: 0) }
        return MotionVector3(x: vector.x / magnitude, y: vector.y / magnitude, z: vector.z / magnitude)
    }

    private func zeroCrossingCount(_ values: [Double], deadband: Double) -> Int {
        var previousSign = 0
        var count = 0
        for value in values {
            let sign: Int
            if value > deadband {
                sign = 1
            } else if value < -deadband {
                sign = -1
            } else {
                sign = 0
            }
            guard sign != 0 else { continue }
            if previousSign != 0, sign != previousSign {
                count += 1
            }
            previousSign = sign
        }
        return count
    }

    private func periodicityScore(_ values: [Double], zeroCrossings: Int) -> Double {
        guard values.count >= 8, zeroCrossings >= 2 else { return 0 }
        let mean = values.reduce(0.0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(values.count)
        let peak = max(values.map { abs($0) }.max() ?? 0, 0.0001)
        let normalizedVariance = min(1, sqrt(variance) / peak)
        let crossingScore = min(1, Double(zeroCrossings) / 6.0)
        return max(0, min(1, crossingScore * 0.65 + normalizedVariance * 0.35))
    }

    private func holdStability(_ samples: [MotionSample]) -> Double {
        let gyros = samples.map(\.rotationRate.magnitude)
        let meanGyro = gyros.reduce(0.0, +) / Double(max(gyros.count, 1))
        let acc = samples.map(\.userAcceleration.magnitude)
        let meanAcc = acc.reduce(0.0, +) / Double(max(acc.count, 1))
        let gyroScore = max(0, 1 - meanGyro / 0.45)
        let accScore = max(0, 1 - meanAcc / 0.22)
        return min(1, gyroScore * 0.65 + accScore * 0.35)
    }

    private func directionalityScore(_ samples: [MotionSample]) -> Double {
        guard samples.count > 1 else { return 0 }
        let sums = [
            samples.map(\.userAcceleration.x).reduce(0.0, +),
            samples.map(\.userAcceleration.y).reduce(0.0, +),
            samples.map(\.userAcceleration.z).reduce(0.0, +),
        ]
        let totalAbs = max(
            samples.map { abs($0.userAcceleration.x) + abs($0.userAcceleration.y) + abs($0.userAcceleration.z) }.reduce(0.0, +),
            0.0001
        )
        return min(1, (sums.map { abs($0) }.max() ?? 0) / totalAbs)
    }

    private func numberOfBursts(_ frames: [MotionEnergyFrame]) -> Int {
        guard frames.count >= 3 else { return 0 }
        let peak = frames.map(\.energy).max() ?? 0
        let threshold = max(0.35, peak * 0.45)
        var count = 0
        var above = false
        for frame in frames {
            if frame.energy >= threshold, !above {
                count += 1
                above = true
            } else if frame.energy < threshold * 0.6 {
                above = false
            }
        }
        return count
    }
}

public struct MotionTokenizer: Sendable {
    public var extractor: MotionFeatureExtractor
    public var windowDuration: Double
    public var hopDuration: Double

    public init(
        extractor: MotionFeatureExtractor = MotionFeatureExtractor(),
        windowDuration: Double = 0.36,
        hopDuration: Double = 0.12
    ) {
        self.extractor = extractor
        self.windowDuration = windowDuration
        self.hopDuration = hopDuration
    }

    public func tokenize(segment: GestureSegment) -> [MotionToken] {
        let fullSegmentToken = makeToken(
            samples: segment.samples,
            start: segment.startTimestamp,
            end: segment.endTimestamp
        )
        guard segment.samples.count >= 8, segment.duration >= windowDuration * 1.35 else {
            return [fullSegmentToken]
        }

        var rawTokens: [MotionToken] = []
        var windowStartIndex = 0
        while windowStartIndex < segment.samples.count - 2 {
            let windowStart = segment.samples[windowStartIndex].timestamp
            let windowEnd = windowStart + windowDuration
            var windowEndIndex = windowStartIndex
            while windowEndIndex + 1 < segment.samples.count,
                  segment.samples[windowEndIndex + 1].timestamp <= windowEnd {
                windowEndIndex += 1
            }

            let count = windowEndIndex - windowStartIndex + 1
            if count >= 6 {
                let samples = Array(segment.samples[windowStartIndex...windowEndIndex])
                let token = makeToken(
                    samples: samples,
                    start: samples.first?.timestamp ?? windowStart,
                    end: samples.last?.timestamp ?? windowEnd
                )
                if token.confidence >= 0.18 || token.kind == .pause {
                    rawTokens.append(token)
                }
            }

            let nextStart = windowStart + hopDuration
            while windowStartIndex + 1 < segment.samples.count,
                  segment.samples[windowStartIndex].timestamp < nextStart {
                windowStartIndex += 1
            }
            if windowStartIndex >= segment.samples.count - 2 {
                break
            }
        }

        let merged = merge(tokens: rawTokens)
        return merged.isEmpty
            ? [fullSegmentToken]
            : [fullSegmentToken] + merged
    }

    private func makeToken(samples: [MotionSample], start: Double, end: Double) -> MotionToken {
        let features = extractor.extract(samples)
        return makeToken(features: features, start: start, end: end)
    }

    public func tokenize(segment: GestureSegment, calibration: TokenizerCalibration?) -> [MotionToken] {
        guard let calibration else {
            return tokenize(segment: segment)
        }
        let fullSegmentToken = makeToken(
            features: extractor.extract(segment.samples),
            start: segment.startTimestamp,
            end: segment.endTimestamp,
            calibration: calibration
        )
        guard segment.samples.count >= 8, segment.duration >= windowDuration * 1.35 else {
            return [fullSegmentToken]
        }

        var rawTokens: [MotionToken] = []
        var windowStartIndex = 0
        while windowStartIndex < segment.samples.count - 2 {
            let windowStart = segment.samples[windowStartIndex].timestamp
            let windowEnd = windowStart + windowDuration
            var windowEndIndex = windowStartIndex
            while windowEndIndex + 1 < segment.samples.count,
                  segment.samples[windowEndIndex + 1].timestamp <= windowEnd {
                windowEndIndex += 1
            }

            let count = windowEndIndex - windowStartIndex + 1
            if count >= 6 {
                let samples = Array(segment.samples[windowStartIndex...windowEndIndex])
                let token = makeToken(
                    features: extractor.extract(samples),
                    start: samples.first?.timestamp ?? windowStart,
                    end: samples.last?.timestamp ?? windowEnd,
                    calibration: calibration
                )
                if token.confidence >= 0.18 || token.kind == .pause {
                    rawTokens.append(token)
                }
            }

            let nextStart = windowStart + hopDuration
            while windowStartIndex + 1 < segment.samples.count,
                  segment.samples[windowStartIndex].timestamp < nextStart {
                windowStartIndex += 1
            }
            if windowStartIndex >= segment.samples.count - 2 {
                break
            }
        }

        let merged = merge(tokens: rawTokens)
        return merged.isEmpty
            ? [fullSegmentToken]
            : [fullSegmentToken] + merged
    }

    private func makeToken(features: GestureSampleFeatures, start: Double, end: Double) -> MotionToken {
        makeToken(features: features, start: start, end: end, calibration: nil)
    }

    private func makeToken(
        features: GestureSampleFeatures,
        start: Double,
        end: Double,
        calibration: TokenizerCalibration?
    ) -> MotionToken {
        let kind = classify(features, calibration: calibration)
        let direction = features.signedRotationAngle >= 0 ? 1.0 : -1.0
        let magnitude = tokenMagnitude(kind: kind, features: features)
        let confidence = tokenConfidence(kind: kind, features: features)
        return MotionToken(
            kind: kind,
            startTime: start,
            endTime: end,
            duration: max(0, end - start),
            mainAxis: features.dominantRotationAxis,
            direction: direction,
            magnitude: magnitude,
            confidence: confidence,
            peakAcc: features.peakAcc,
            peakGyro: features.peakGyro,
            integratedAngle: features.integratedRotationAngle,
            oscillationCount: features.oscillationCount,
            holdStability: features.holdStability
        )
    }

    private func merge(tokens: [MotionToken]) -> [MotionToken] {
        var output: [MotionToken] = []
        for token in tokens {
            guard var last = output.last,
                  last.kind == token.kind,
                  token.startTime <= last.endTime + hopDuration * 1.5 else {
                output.append(token)
                continue
            }

            last.endTime = max(last.endTime, token.endTime)
            last.duration = max(0, last.endTime - last.startTime)
            last.magnitude = max(last.magnitude, token.magnitude)
            last.confidence = max(last.confidence, token.confidence)
            last.peakAcc = maxOptional(last.peakAcc, token.peakAcc)
            last.peakGyro = maxOptional(last.peakGyro, token.peakGyro)
            last.integratedAngle = maxOptional(last.integratedAngle, token.integratedAngle)
            last.oscillationCount = maxOptional(last.oscillationCount, token.oscillationCount)
            last.holdStability = maxOptional(last.holdStability, token.holdStability)
            output[output.count - 1] = last
        }
        return output
    }

    private func maxOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return max(lhs, rhs)
        case let (.some(value), .none), let (.none, .some(value)):
            return value
        case (.none, .none):
            return nil
        }
    }

    public func classify(_ features: GestureSampleFeatures) -> MotionTokenKind {
        classify(features, calibration: nil)
    }

    public func classify(_ features: GestureSampleFeatures, calibration: TokenizerCalibration?) -> MotionTokenKind {
        let impulsePeakAcc = max(0.18, (calibration?.impulsePeakAccP20 ?? 1.6) * 0.72)
        let impulsePeakGyro = max(0.35, (calibration?.impulsePeakGyroP20 ?? 6.0) * 0.72)
        let rotationAngle = max(.pi * 0.45, (calibration?.rotationAngleP20 ?? .pi * 1.15) * 0.70)
        let rotationStability = max(0.38, (calibration?.rotationAxisStabilityP20 ?? 0.55) * 0.78)
        let oscillationCount = max(1.0, (calibration?.oscillationCountP20 ?? 1.5) * 0.75)
        let periodicity = max(0.24, (calibration?.periodicityP20 ?? 0.35) * 0.75)
        let holdStability = max(0.58, (calibration?.holdStabilityP20 ?? 0.78) * 0.82)

        if features.duration >= 0.35,
           features.holdStability >= holdStability,
           features.peakGyro < 0.45,
           features.peakAcc < 0.28 {
            return .hold
        }

        if features.integratedRotationAngle >= rotationAngle,
           features.rotationAxisStability >= rotationStability,
           features.zeroCrossingCount <= max(5, Int(features.duration * 2.5)),
           features.duration >= 0.45 {
            return .rotation
        }

        if Double(features.zeroCrossingCount) / 2.0 >= oscillationCount,
           features.periodicityScore >= periodicity,
           features.duration >= 0.45 {
            return .oscillation
        }

        if (features.peakAcc >= impulsePeakAcc || features.peakJerk >= 32 || features.peakGyro >= impulsePeakGyro),
           features.duration <= 2.2 {
            return .impulse
        }

        if features.directionalityScore >= 0.42,
           features.duration <= 2.0,
           features.peakAcc >= 0.25 {
            return .sweep
        }

        if features.meanAcc < 0.04, features.meanGyro < 0.08 {
            return .pause
        }

        return .free
    }

    private func tokenMagnitude(kind: MotionTokenKind, features: GestureSampleFeatures) -> Double {
        switch kind {
        case .impulse:
            return max(features.peakAcc, features.peakGyro * 0.2)
        case .rotation:
            return features.integratedRotationAngle
        case .oscillation:
            return features.oscillationCount
        case .hold:
            return features.holdDuration
        case .sweep:
            return features.directionalityScore
        case .pause:
            return features.duration
        case .free:
            return max(features.meanAcc, features.meanGyro * 0.25)
        }
    }

    private func tokenConfidence(kind: MotionTokenKind, features: GestureSampleFeatures) -> Double {
        switch kind {
        case .impulse:
            return clamp(max(features.peakAcc / 2.0, features.peakGyro / 8.0, features.peakJerk / 80.0))
        case .rotation:
            return clamp(features.rotationAxisStability * 0.55 + min(1, features.integratedRotationAngle / (.pi * 2)) * 0.45)
        case .oscillation:
            return clamp(features.periodicityScore * 0.65 + min(1, features.oscillationCount / 2.0) * 0.35)
        case .hold:
            return clamp(features.holdStability)
        case .sweep:
            return clamp(features.directionalityScore)
        case .pause:
            return clamp(1 - max(features.meanAcc / 0.08, features.meanGyro / 0.16))
        case .free:
            return 0.35
        }
    }

    private func clamp(_ value: Double) -> Double {
        max(0, min(1, value))
    }
}

public struct MotionStageObservation: Equatable, Sendable {
    public var kind: MotionTokenKind
    public var duration: Double
    public var magnitude: Double

    public init(kind: MotionTokenKind, duration: Double, magnitude: Double) {
        self.kind = kind
        self.duration = duration
        self.magnitude = magnitude
    }
}

public struct MotionStageMatchResult: Equatable, Sendable {
    public var score: Double
    public var rejectReason: RejectReason?

    public init(score: Double, rejectReason: RejectReason? = nil) {
        self.score = score
        self.rejectReason = rejectReason
    }
}

public struct PrimitiveRecognitionResult: Equatable, Sendable {
    public var kind: MotionTokenKind
    public var score: Double
    public var rejectReason: RejectReason?

    public init(kind: MotionTokenKind, score: Double, rejectReason: RejectReason? = nil) {
        self.kind = kind
        self.score = max(0, min(1, score))
        self.rejectReason = rejectReason
    }
}

public protocol MotionPrimitiveRecognizer: Sendable {
    var kind: MotionTokenKind { get }
}

public struct ImpulsePrimitiveRecognizer: MotionPrimitiveRecognizer {
    public let kind = MotionTokenKind.impulse
    public init() {}

    public func score(features: GestureSampleFeatures, signature: ImpulseSignature) -> PrimitiveRecognitionResult {
        guard features.peakAcc >= max(0.18, signature.peakAcc * 0.22)
            || features.peakGyro >= max(0.4, signature.peakGyro * 0.22) else {
            return PrimitiveRecognitionResult(kind: kind, score: 0.2, rejectReason: .impulsePeakTooWeak)
        }
        let peakScore = primitiveRatioScore(value: features.peakAcc, reference: signature.peakAcc, lower: 0.25, upper: 2.4)
        let gyroScore = primitiveRatioScore(value: features.peakGyro, reference: signature.peakGyro, lower: 0.22, upper: 2.8)
        let durationScore = primitiveRatioScore(value: features.duration, reference: signature.duration, lower: 0.45, upper: 1.85)
        let directionScore = features.signedRotationAngle.sign == signature.direction.sign ? 1.0 : 0.55
        let score = peakScore * 0.30 + gyroScore * 0.22 + durationScore * 0.23 + directionScore * 0.25
        return PrimitiveRecognitionResult(kind: kind, score: score, rejectReason: score >= 0.55 ? nil : .scoreBelowThreshold)
    }
}

public struct RotationPrimitiveRecognizer: MotionPrimitiveRecognizer {
    public let kind = MotionTokenKind.rotation
    public init() {}

    public func score(features: GestureSampleFeatures, signature: RotationSignature) -> PrimitiveRecognitionResult {
        let minAngle = max(.pi * 0.65, signature.totalAngleRadians * 0.68)
        guard features.integratedRotationAngle >= minAngle else {
            return PrimitiveRecognitionResult(kind: kind, score: 0.25, rejectReason: .rotationAngleTooSmall)
        }
        let consistency = features.rotationDirectionConsistency
        guard consistency >= 0.42 else {
            return PrimitiveRecognitionResult(kind: kind, score: 0.35, rejectReason: .rotationDirectionMismatch)
        }
        let angleScore = primitiveRatioScore(value: features.integratedRotationAngle, reference: signature.totalAngleRadians, lower: 0.48, upper: 1.85)
        let axisAlignment = abs(dot(features.dominantRotationAxis, signature.axis))
        let axisScore = primitiveClamp(features.rotationAxisStability / max(signature.axisStability * 0.75, 0.25)) * axisAlignment
        let durationScore = primitiveRatioScore(value: features.duration, reference: signature.duration, lower: 0.35, upper: 2.6)
        let directionScore = features.signedRotationAngle.sign == signature.direction.sign ? 1.0 : 0.60
        let speedScore = primitiveRatioScore(value: features.meanGyro, reference: max(signature.angularSpeedMean, 0.05), lower: 0.20, upper: 3.4)
        let consistencyScore = primitiveRatioScore(value: consistency, reference: 0.82, lower: 0.50, upper: 1.22)
        let score = angleScore * 0.24
            + axisScore * 0.23
            + durationScore * 0.11
            + directionScore * 0.12
            + speedScore * 0.10
            + consistencyScore * 0.20
        let reason: RejectReason? = axisScore < 0.45
            ? .rotationAxisUnstable
            : (score >= 0.55 ? nil : .scoreBelowThreshold)
        return PrimitiveRecognitionResult(kind: kind, score: score, rejectReason: reason)
    }
}

public struct OscillationPrimitiveRecognizer: MotionPrimitiveRecognizer {
    public let kind = MotionTokenKind.oscillation
    public init() {}

    public func score(features: GestureSampleFeatures, signature: OscillationSignature) -> PrimitiveRecognitionResult {
        guard features.oscillationCount >= max(0.5, signature.count * 0.45) else {
            return PrimitiveRecognitionResult(kind: kind, score: 0.25, rejectReason: .oscillationCountTooLow)
        }
        let countScore = primitiveRatioScore(value: features.oscillationCount, reference: signature.count, lower: 0.45, upper: 1.9)
        let periodicityScore = primitiveClamp(features.periodicityScore / max(signature.periodicityScore * 0.75, 0.2))
        let durationScore = primitiveRatioScore(value: features.duration, reference: signature.duration, lower: 0.45, upper: 2.2)
        let magnitudeScore = primitiveRatioScore(value: features.peakGyro, reference: signature.magnitude, lower: 0.25, upper: 2.8)
        let score = countScore * 0.34 + periodicityScore * 0.28 + durationScore * 0.18 + magnitudeScore * 0.20
        let reason: RejectReason? = periodicityScore < 0.42 ? .oscillationNotPeriodic : (score >= 0.55 ? nil : .scoreBelowThreshold)
        return PrimitiveRecognitionResult(kind: kind, score: score, rejectReason: reason)
    }
}

public struct HoldPrimitiveRecognizer: MotionPrimitiveRecognizer {
    public let kind = MotionTokenKind.hold
    public init() {}

    public func score(features: GestureSampleFeatures, signature: HoldSignature) -> PrimitiveRecognitionResult {
        guard features.holdDuration >= max(0.25, signature.duration * 0.55) else {
            return PrimitiveRecognitionResult(kind: kind, score: 0.25, rejectReason: .holdTooShort)
        }
        let stabilityScore = primitiveClamp(features.holdStability / max(signature.stability * 0.80, 0.2))
        let durationScore = primitiveRatioScore(value: features.duration, reference: signature.duration, lower: 0.55, upper: 1.8)
        let gyroScore = 1 - primitiveClamp(features.meanGyro / max(signature.meanGyro * 2.2, 0.2))
        let score = stabilityScore * 0.45 + durationScore * 0.30 + gyroScore * 0.25
        return PrimitiveRecognitionResult(kind: kind, score: score, rejectReason: score >= 0.55 ? nil : .holdNotStable)
    }
}

private func primitiveClamp(_ value: Double) -> Double {
    max(0, min(1, value))
}

private func primitiveRatioScore(value: Double, reference: Double, lower: Double, upper: Double) -> Double {
    guard reference > 0.0001 else { return value < 0.0001 ? 1 : 0 }
    let ratio = value / reference
    if ratio >= lower, ratio <= upper {
        let center = 1.0
        let spread = ratio < center ? center - lower : upper - center
        return primitiveClamp(1 - abs(ratio - center) / max(spread * 1.25, 0.0001))
    }
    if ratio < lower {
        return primitiveClamp(ratio / lower * 0.55)
    }
    return primitiveClamp(upper / ratio * 0.55)
}

public struct MotionStageExtractor: Sendable {
    public var tokenizer: MotionTokenizer
    public var extractor: MotionFeatureExtractor

    public init(
        tokenizer: MotionTokenizer = MotionTokenizer(),
        extractor: MotionFeatureExtractor = MotionFeatureExtractor()
    ) {
        self.tokenizer = tokenizer
        self.extractor = extractor
    }

    public func makeSignature(templates: [MotionTemplate]) -> [MotionStageSignature] {
        let observations = templates.map { stages(for: $0.samples) }
        guard let maxCount = observations.map(\.count).max(), maxCount > 0 else {
            return []
        }

        var output: [MotionStageSignature] = []
        for index in 0..<maxCount {
            let values = observations.compactMap { stages in
                stages.indices.contains(index) ? stages[index] : nil
            }
            guard values.count >= max(1, Int(ceil(Double(observations.count) * 0.55))) else {
                continue
            }
            let kind = mostFrequentKind(values.map(\.kind))
            let durations = values.filter { $0.kind == kind }.map(\.duration)
            let magnitudes = values.filter { $0.kind == kind }.map(\.magnitude)
            let duration = average(durations.isEmpty ? values.map(\.duration) : durations)
            let magnitude = average(magnitudes.isEmpty ? values.map(\.magnitude) : magnitudes)
            output.append(MotionStageSignature(
                kind: kind,
                minDuration: max(0.06, duration * 0.45),
                maxDuration: max(0.16, duration * 1.9),
                expectedMagnitude: magnitude
            ))
        }
        return output
    }

    public func stages(for samples: [MotionSample]) -> [MotionStageObservation] {
        guard samples.count >= 4 else { return [] }
        if let holdStartIndex = terminalHoldStartIndex(samples),
           holdStartIndex > samples.startIndex + 3,
           holdStartIndex < samples.endIndex - 2 {
            let movement = Array(samples[..<holdStartIndex])
            let hold = Array(samples[holdStartIndex...])
            var output = [stage(for: movement)]
            output.append(MotionStageObservation(
                kind: .hold,
                duration: duration(hold),
                magnitude: max(0.05, 1 - extractor.extract(hold).meanGyro)
            ))
            return output
        }
        return [stage(for: samples)]
    }

    public func match(signature: [MotionStageSignature]?, samples: [MotionSample]) -> MotionStageMatchResult? {
        guard let signature, !signature.isEmpty else { return nil }
        let observations = stages(for: samples)
        guard !observations.isEmpty else {
            return MotionStageMatchResult(score: 0, rejectReason: .stageMismatch)
        }

        let comparedCount = min(signature.count, observations.count)
        var scores: [Double] = []
        scores.reserveCapacity(comparedCount)

        for index in 0..<comparedCount {
            let expected = signature[index]
            let observed = observations[index]
            let kindScore = stageKindScore(expected: expected.kind, observed: observed.kind)
            let durationScore = ratioScore(value: observed.duration, reference: max(0.01, (expected.minDuration + expected.maxDuration) * 0.5), lower: 0.45, upper: 1.9)
            let magnitudeScore = ratioScore(value: observed.magnitude, reference: max(0.01, expected.expectedMagnitude), lower: 0.25, upper: 2.8)
            scores.append(kindScore * 0.52 + durationScore * 0.24 + magnitudeScore * 0.24)
        }

        let missingPenalty = observations.count < signature.count ? 0.58 : 1.0
        let extraPenalty = observations.count > signature.count + 1 ? 0.86 : 1.0
        let score = clamp(average(scores) * missingPenalty * extraPenalty)
        let expectsHold = signature.contains { $0.kind == .hold }
        let observedHold = observations.contains { $0.kind == .hold }
        let rejectReason: RejectReason? = expectsHold && !observedHold ? .stageMismatch : (score < 0.34 ? .stageMismatch : nil)
        return MotionStageMatchResult(score: score, rejectReason: rejectReason)
    }

    private func stage(for samples: [MotionSample]) -> MotionStageObservation {
        let features = extractor.extract(samples)
        let kind = tokenizer.classify(features)
        return MotionStageObservation(
            kind: kind,
            duration: features.duration,
            magnitude: magnitude(kind: kind, features: features)
        )
    }

    private func terminalHoldStartIndex(_ samples: [MotionSample]) -> Int? {
        guard samples.count >= 8, let last = samples.last else { return nil }
        var startIndex: Int?
        for index in stride(from: samples.count - 1, through: 0, by: -1) {
            let sample = samples[index]
            let stable = sample.userAcceleration.magnitude <= 0.28 && sample.rotationRate.magnitude <= 0.72
            if stable {
                startIndex = index
            } else if startIndex != nil {
                break
            }
        }
        guard let startIndex else { return nil }
        let duration = max(0, last.timestamp - samples[startIndex].timestamp)
        return duration >= 0.20 ? startIndex : nil
    }

    private func magnitude(kind: MotionTokenKind, features: GestureSampleFeatures) -> Double {
        switch kind {
        case .impulse:
            return max(features.peakAcc, features.peakGyro * 0.2)
        case .rotation:
            return features.integratedRotationAngle
        case .oscillation:
            return features.oscillationCount
        case .hold:
            return features.holdDuration
        case .sweep:
            return features.directionalityScore
        case .pause:
            return features.duration
        case .free:
            return max(features.meanAcc, features.meanGyro * 0.25)
        }
    }

    private func stageKindScore(expected: MotionTokenKind, observed: MotionTokenKind) -> Double {
        if expected == observed {
            return 1.0
        }
        switch (expected, observed) {
        case (.impulse, .sweep), (.sweep, .impulse),
             (.rotation, .oscillation), (.oscillation, .rotation):
            return 0.58
        case (.hold, _), (_, .hold):
            return 0.18
        default:
            return 0.36
        }
    }

    private func mostFrequentKind(_ kinds: [MotionTokenKind]) -> MotionTokenKind {
        Dictionary(grouping: kinds, by: { $0 })
            .max { $0.value.count < $1.value.count }?
            .key ?? .free
    }

    private func duration(_ samples: [MotionSample]) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.timestamp - first.timestamp)
    }
}

public struct MotionPoseSummary: Equatable, Sendable {
    public var startGravity: MotionVector3
    public var endGravity: MotionVector3
    public var gravityDelta: MotionVector3
    public var terminalHoldDuration: Double

    public init(
        startGravity: MotionVector3,
        endGravity: MotionVector3,
        gravityDelta: MotionVector3,
        terminalHoldDuration: Double
    ) {
        self.startGravity = startGravity
        self.endGravity = endGravity
        self.gravityDelta = gravityDelta
        self.terminalHoldDuration = terminalHoldDuration
    }
}

public struct MotionPoseMatchResult: Equatable, Sendable {
    public var score: Double
    public var rejectReason: RejectReason?

    public init(score: Double, rejectReason: RejectReason? = nil) {
        self.score = score
        self.rejectReason = rejectReason
    }
}

public struct MotionPoseAnalyzer: Sendable {
    public init() {}

    public func makeSignature(templates: [MotionTemplate]) -> MotionPoseSignature? {
        let summaries = templates.compactMap { summarize($0.samples) }
        guard !summaries.isEmpty else { return nil }

        let startGravity = averageVector(summaries.map(\.startGravity))
        let endGravity = averageVector(summaries.map(\.endGravity))
        let gravityDelta = averageVector(summaries.map(\.gravityDelta))
        let terminalHoldDuration = average(summaries.map(\.terminalHoldDuration))
        let endConsistency = vectorConsistency(summaries.map(\.endGravity), reference: endGravity)
        let deltaConsistency = gravityDelta.magnitude >= 0.08
            ? vectorConsistency(summaries.map(\.gravityDelta), reference: gravityDelta)
            : 0.5
        let holdConfidence = min(1, terminalHoldDuration / 0.45)
        let confidence = clamp(endConsistency * 0.55 + deltaConsistency * 0.25 + holdConfidence * 0.20)

        return MotionPoseSignature(
            startGravity: startGravity,
            endGravity: endGravity,
            gravityDelta: gravityDelta,
            terminalHoldDuration: terminalHoldDuration,
            confidence: confidence
        )
    }

    public func summarize(_ samples: [MotionSample]) -> MotionPoseSummary? {
        let gravitySamples = samples.compactMap { sample -> (timestamp: Double, gravity: MotionVector3)? in
            guard let gravity = sample.gravity else { return nil }
            return (sample.timestamp, gravity)
        }
        guard gravitySamples.count >= 4 else { return nil }

        let windowCount = max(2, Int(ceil(Double(gravitySamples.count) * 0.16)))
        let startGravity = averageVector(gravitySamples.prefix(windowCount).map(\.gravity))
        let endGravity = averageVector(gravitySamples.suffix(windowCount).map(\.gravity))
        let terminalHoldDuration = stableSuffixDuration(samples)
        return MotionPoseSummary(
            startGravity: startGravity,
            endGravity: endGravity,
            gravityDelta: endGravity - startGravity,
            terminalHoldDuration: terminalHoldDuration
        )
    }

    public func match(signature: MotionPoseSignature?, samples: [MotionSample]) -> MotionPoseMatchResult? {
        guard let signature, signature.confidence >= 0.42, let summary = summarize(samples) else {
            return nil
        }
        let endScore = vectorSimilarity(summary.endGravity, signature.endGravity)
        let startScore = vectorSimilarity(summary.startGravity, signature.startGravity)
        let deltaScore = signature.gravityDelta.magnitude >= 0.08 && summary.gravityDelta.magnitude >= 0.04
            ? vectorSimilarity(summary.gravityDelta, signature.gravityDelta)
            : 0.72
        let holdScore = signature.terminalHoldDuration >= 0.18
            ? ratioScore(value: summary.terminalHoldDuration, reference: signature.terminalHoldDuration, lower: 0.40, upper: 2.5)
            : 0.78
        let score = clamp(endScore * 0.42 + deltaScore * 0.24 + holdScore * 0.22 + startScore * 0.12)

        let terminalHoldMissing = signature.terminalHoldDuration >= 0.22
            && summary.terminalHoldDuration < signature.terminalHoldDuration * 0.35
        let endPoseMismatch = signature.confidence >= 0.50 && endScore < 0.62
        let rejectReason: RejectReason? = terminalHoldMissing || endPoseMismatch || (signature.confidence >= 0.62 && score < 0.36)
            ? .poseMismatch
            : nil
        return MotionPoseMatchResult(score: score, rejectReason: rejectReason)
    }

    private func stableSuffixDuration(_ samples: [MotionSample]) -> Double {
        guard samples.count >= 4, let last = samples.last else { return 0 }
        var startTimestamp = last.timestamp
        for sample in samples.reversed() {
            let stable = sample.userAcceleration.magnitude <= 0.28 && sample.rotationRate.magnitude <= 0.72
            guard stable else { break }
            startTimestamp = sample.timestamp
        }
        return max(0, last.timestamp - startTimestamp)
    }
}

public struct GestureSignatureBuilder: Sendable {
    public var tokenizer: MotionTokenizer
    public var extractor: MotionFeatureExtractor
    public var stageExtractor: MotionStageExtractor
    public var poseAnalyzer: MotionPoseAnalyzer

    public init(
        tokenizer: MotionTokenizer = MotionTokenizer(),
        extractor: MotionFeatureExtractor = MotionFeatureExtractor(),
        stageExtractor: MotionStageExtractor = MotionStageExtractor(),
        poseAnalyzer: MotionPoseAnalyzer = MotionPoseAnalyzer()
    ) {
        self.tokenizer = tokenizer
        self.extractor = extractor
        self.stageExtractor = stageExtractor
        self.poseAnalyzer = poseAnalyzer
    }

    public func makeSignature(templates: [MotionTemplate]) -> GestureSignature {
        let templateFeatures = templates.map { extractor.extract($0.samples) }
        let calibration = makeTokenizerCalibration(features: templateFeatures)
        let primary = primaryKind(features: templateFeatures)
        let secondary = secondaryKinds(features: templateFeatures, primary: primary)
        let patterns = templateFeatures.map {
            let kind = tokenizer.classify($0, calibration: calibration)
            return MotionTokenPattern(
                kind: kind,
                minDuration: max(0, $0.duration * 0.55),
                maxDuration: max($0.duration * 1.65, 0.25),
                expectedMagnitude: expectedMagnitude(kind: kind, features: $0)
            )
        }
        return GestureSignature(
            primaryKind: primary,
            secondaryKinds: secondary,
            tokenPatterns: patterns,
            tokenizerCalibration: calibration,
            fusionPolicy: makeFusionPolicy(primaryKind: primary, templateCount: templates.count),
            stages: stageExtractor.makeSignature(templates: templates),
            pose: poseAnalyzer.makeSignature(templates: templates),
            impulse: makeImpulseSignature(features: templateFeatures),
            rotation: makeRotationSignature(features: templateFeatures),
            oscillation: makeOscillationSignature(features: templateFeatures),
            hold: makeHoldSignature(features: templateFeatures),
            fallbackTemplates: templates.map { NormalizedMotionTemplate(templateID: $0.id, samples: $0.samples) }
        )
    }

    public func makeThresholds(signature: GestureSignature, templateCount: Int, strictness: Double) -> ThresholdProfile {
        let base: Double
        switch signature.primaryKind {
        case .impulse:
            base = templateCount >= 3 ? 0.70 : 0.76
        case .rotation:
            base = templateCount >= 3 ? 0.62 : 0.70
        case .oscillation:
            base = templateCount >= 3 ? 0.58 : 0.69
        case .hold:
            base = 0.72
        case .sweep:
            base = 0.68
        case .pause:
            base = 0.82
        case .free:
            base = templateCount >= 3 ? 0.70 : 0.76
        }
        let strictAdjustment = (strictness - 0.5) * 0.14
        let singleTemplateAdjustment = templateCount <= 1 ? 0.05 : 0
        let marginScore = templateCount >= 3 ? 0.06 : (templateCount == 2 ? 0.08 : 0.14)
        return ThresholdProfile(
            triggerScore: max(0.52, min(0.92, base + strictAdjustment + singleTemplateAdjustment)),
            rejectScore: max(0.35, base - 0.22),
            marginScore: marginScore,
            minEnergy: signature.primaryKind == .impulse ? 0.25 : nil,
            minAngle: signature.rotation.map { max(.pi * 0.75, $0.totalAngleRadians * 0.70) },
            minOscillationCount: signature.oscillation.map { max(0.5, $0.count * 0.55) },
            minHoldDuration: signature.hold.map { max(0.25, $0.duration * 0.65) },
            strictness: strictness,
            fusionPolicy: signature.fusionPolicy ?? makeFusionPolicy(primaryKind: signature.primaryKind, templateCount: templateCount)
        )
    }

    private func primaryKind(features: [GestureSampleFeatures]) -> MotionTokenKind {
        let calibration = makeTokenizerCalibration(features: features)
        let kinds = features.map { tokenizer.classify($0, calibration: calibration) }
        if let winner = Dictionary(grouping: kinds, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            return winner
        }
        return .free
    }

    private func secondaryKinds(features: [GestureSampleFeatures], primary: MotionTokenKind) -> [MotionTokenKind] {
        let calibration = makeTokenizerCalibration(features: features)
        let kinds = Array(Set(features.map { tokenizer.classify($0, calibration: calibration) })).filter { $0 != primary }
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    private func makeTokenizerCalibration(features: [GestureSampleFeatures]) -> TokenizerCalibration {
        TokenizerCalibration(
            impulsePeakAccP20: percentile(features.map(\.peakAcc), pct: 0.20),
            impulsePeakGyroP20: percentile(features.map(\.peakGyro), pct: 0.20),
            rotationAngleP20: percentile(features.map(\.integratedRotationAngle), pct: 0.20),
            rotationAxisStabilityP20: percentile(features.map(\.rotationAxisStability), pct: 0.20),
            oscillationCountP20: percentile(features.map(\.oscillationCount), pct: 0.20),
            periodicityP20: percentile(features.map(\.periodicityScore), pct: 0.20),
            holdStabilityP20: percentile(features.map(\.holdStability), pct: 0.20)
        )
    }

    private func makeFusionPolicy(primaryKind: MotionTokenKind, templateCount: Int) -> RecognitionFusionPolicy {
        let qualityRelax = templateCount >= 3 ? 0.10 : 0
        switch primaryKind {
        case .rotation:
            return RecognitionFusionPolicy(
                trajectoryWeight: 0.24,
                semanticWeight: 0.48,
                stageWeight: 0.12,
                poseWeight: 0.10,
                maxSoftDistanceRatio: 2.20 + qualityRelax,
                requireHardVetoPass: true
            )
        case .impulse, .sweep:
            return RecognitionFusionPolicy(
                trajectoryWeight: 0.58,
                semanticWeight: 0.24,
                stageWeight: 0.10,
                poseWeight: 0.08,
                maxSoftDistanceRatio: 1.22 + qualityRelax,
                requireHardVetoPass: true
            )
        case .hold:
            return RecognitionFusionPolicy(
                trajectoryWeight: 0.24,
                semanticWeight: 0.20,
                stageWeight: 0.16,
                poseWeight: 0.34,
                maxSoftDistanceRatio: 1.15 + qualityRelax,
                requireHardVetoPass: true
            )
        case .oscillation:
            return RecognitionFusionPolicy(
                trajectoryWeight: 0.34,
                semanticWeight: 0.42,
                stageWeight: 0.14,
                poseWeight: 0.06,
                maxSoftDistanceRatio: 1.38 + qualityRelax,
                requireHardVetoPass: true
            )
        case .pause, .free:
            return RecognitionFusionPolicy(
                trajectoryWeight: 0.64,
                semanticWeight: 0.18,
                stageWeight: 0.08,
                poseWeight: 0.06,
                maxSoftDistanceRatio: 1.18,
                requireHardVetoPass: true
            )
        }
    }

    private func makeImpulseSignature(features: [GestureSampleFeatures]) -> ImpulseSignature? {
        let calibration = makeTokenizerCalibration(features: features)
        let impulses = features.filter { tokenizer.classify($0, calibration: calibration) == .impulse || $0.peakAcc >= 1.0 || $0.peakGyro >= 4.0 }
        guard !impulses.isEmpty else { return nil }
        return ImpulseSignature(
            mainAxis: averageAxis(impulses.map(\.dominantRotationAxis)),
            direction: average(impulses.map { $0.signedRotationAngle >= 0 ? 1 : -1 }) >= 0 ? 1 : -1,
            peakAcc: average(impulses.map(\.peakAcc)),
            peakGyro: average(impulses.map(\.peakGyro)),
            duration: average(impulses.map(\.duration)),
            reboundRatio: 0.5
        )
    }

    private func makeRotationSignature(features: [GestureSampleFeatures]) -> RotationSignature? {
        let calibration = makeTokenizerCalibration(features: features)
        let rotations = features.filter { tokenizer.classify($0, calibration: calibration) == .rotation || ($0.integratedRotationAngle >= .pi * 1.15 && $0.rotationAxisStability >= 0.55) }
        guard !rotations.isEmpty else { return nil }
        let angle = average(rotations.map(\.integratedRotationAngle))
        return RotationSignature(
            axis: averageAxis(rotations.map(\.dominantRotationAxis)),
            direction: average(rotations.map { $0.signedRotationAngle >= 0 ? 1 : -1 }) >= 0 ? 1 : -1,
            totalAngleRadians: angle,
            circleCount: angle / (.pi * 2),
            duration: average(rotations.map(\.duration)),
            axisStability: average(rotations.map(\.rotationAxisStability)),
            angularSpeedMean: average(rotations.map(\.meanGyro)),
            angularSpeedStd: standardDeviation(rotations.map(\.meanGyro))
        )
    }

    private func makeOscillationSignature(features: [GestureSampleFeatures]) -> OscillationSignature? {
        let calibration = makeTokenizerCalibration(features: features)
        let oscillations = features.filter { tokenizer.classify($0, calibration: calibration) == .oscillation || $0.oscillationCount >= 1.5 }
        guard !oscillations.isEmpty else { return nil }
        return OscillationSignature(
            axis: averageAxis(oscillations.map(\.dominantRotationAxis)),
            count: average(oscillations.map(\.oscillationCount)),
            duration: average(oscillations.map(\.duration)),
            periodicityScore: average(oscillations.map(\.periodicityScore)),
            magnitude: average(oscillations.map(\.peakGyro))
        )
    }

    private func makeHoldSignature(features: [GestureSampleFeatures]) -> HoldSignature? {
        let calibration = makeTokenizerCalibration(features: features)
        let holds = features.filter { tokenizer.classify($0, calibration: calibration) == .hold || $0.holdStability >= 0.78 }
        guard !holds.isEmpty else { return nil }
        return HoldSignature(
            duration: average(holds.map(\.duration)),
            stability: average(holds.map(\.holdStability)),
            meanGyro: average(holds.map(\.meanGyro))
        )
    }

    private func expectedMagnitude(kind: MotionTokenKind, features: GestureSampleFeatures) -> Double {
        switch kind {
        case .impulse:
            return features.peakAcc
        case .rotation:
            return features.integratedRotationAngle
        case .oscillation:
            return features.oscillationCount
        case .hold:
            return features.holdDuration
        case .sweep:
            return features.directionalityScore
        case .pause:
            return features.duration
        case .free:
            return features.meanAcc + features.meanGyro * 0.25
        }
    }

    private func averageAxis(_ axes: [MotionVector3]) -> MotionVector3 {
        guard !axes.isEmpty else { return MotionVector3(x: 1, y: 0, z: 0) }
        let summed = MotionVector3(
            x: axes.map(\.x).reduce(0.0, +),
            y: axes.map(\.y).reduce(0.0, +),
            z: axes.map(\.z).reduce(0.0, +)
        )
        return normalized(summed)
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0.0, +) / Double(values.count)
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = average(values)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(values.count)
        return sqrt(variance)
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
}

public struct GestureProfileVariantBuilder: Sendable {
    public var matcher: MotionTemplateMatcher
    public var signatureBuilder: GestureSignatureBuilder
    public var evaluator: GestureQualityEvaluator
    public var extractor: MotionFeatureExtractor
    public var tokenizer: MotionTokenizer
    public var maximumVariantCount: Int
    public var clusterDistanceThreshold: Double

    public init(
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        signatureBuilder: GestureSignatureBuilder = GestureSignatureBuilder(),
        evaluator: GestureQualityEvaluator = GestureQualityEvaluator(),
        extractor: MotionFeatureExtractor = MotionFeatureExtractor(),
        tokenizer: MotionTokenizer = MotionTokenizer(),
        maximumVariantCount: Int = 4,
        clusterDistanceThreshold: Double = 0.24
    ) {
        self.matcher = matcher
        self.signatureBuilder = signatureBuilder
        self.evaluator = evaluator
        self.extractor = extractor
        self.tokenizer = tokenizer
        self.maximumVariantCount = maximumVariantCount
        self.clusterDistanceThreshold = clusterDistanceThreshold
    }

    public func makeVariants(
        templates: [MotionTemplate],
        negativeTemplates: [MotionTemplate] = [],
        strictness: Double = 0.5,
        existingProfiles: [GestureProfile] = []
    ) -> [GestureProfileVariant] {
        guard !templates.isEmpty else { return [] }

        let clusters = limitedClusters(clusterTemplates(templates))
        let useVariantLabels = clusters.count > 1

        return clusters.enumerated().map { index, cluster in
            let signature = signatureBuilder.makeSignature(templates: cluster)
            let calibration = matcher.calibrateThreshold(
                positiveTemplates: cluster,
                negativeWindows: negativeTemplates.map(\.samples)
            )
            var thresholds = signatureBuilder.makeThresholds(
                signature: signature,
                templateCount: cluster.count,
                strictness: strictness
            )
            if cluster.count == 1 {
                thresholds.triggerScore = max(thresholds.triggerScore, 0.80)
                thresholds.marginScore = max(thresholds.marginScore, 0.14)
            }
            let quality = evaluator.evaluate(
                templates: cluster,
                negativeTemplates: negativeTemplates,
                existingProfiles: existingProfiles
            ).quality
            return GestureProfileVariant(
                label: useVariantLabels ? "变体 \(index + 1)" : "主变体",
                templateIDs: cluster.map(\.id),
                signature: signature,
                thresholds: thresholds,
                acceptanceThreshold: calibration.threshold,
                marginThreshold: calibration.recommendedMarginThreshold,
                quality: quality
            )
        }
    }

    private func clusterTemplates(_ templates: [MotionTemplate]) -> [[MotionTemplate]] {
        guard templates.count > 1 else { return templates.map { [$0] } }

        var clusters: [[MotionTemplate]] = []
        for template in templates {
            let templateFeatures = extractor.extract(template.samples)
            let templateKind = tokenizer.classify(templateFeatures)
            var bestIndex: Int?
            var bestDistance = Double.infinity

            for index in clusters.indices {
                guard let representative = clusters[index].first else { continue }
                let representativeFeatures = extractor.extract(representative.samples)
                let representativeKind = tokenizer.classify(representativeFeatures)
                guard areCompatibleKinds(templateKind, representativeKind) else { continue }
                guard durationRatio(template.rawDuration, representative.rawDuration) <= 2.8 else { continue }

                let averageDistance = clusters[index]
                    .map { matcher.distance($0.samples, template.samples) }
                    .reduce(0.0, +) / Double(clusters[index].count)
                if dominantAxis(template) != dominantAxis(representative),
                   averageDistance > clusterDistanceThreshold * 0.55 {
                    continue
                }
                if averageDistance < bestDistance {
                    bestDistance = averageDistance
                    bestIndex = index
                }
            }

            if let bestIndex, bestDistance <= clusterDistanceThreshold {
                clusters[bestIndex].append(template)
            } else {
                clusters.append([template])
            }
        }
        return clusters
    }

    private func limitedClusters(_ input: [[MotionTemplate]]) -> [[MotionTemplate]] {
        var clusters = input.filter { !$0.isEmpty }
        while clusters.count > max(1, maximumVariantCount) {
            let singletonIndex = clusters.indices
                .filter { clusters[$0].count == 1 }
                .first ?? clusters.indices.last!
            let moving = clusters.remove(at: singletonIndex)
            guard let template = moving.first else { continue }

            let targetIndex = clusters.indices.min { lhs, rhs in
                averageDistance(from: template, to: clusters[lhs]) < averageDistance(from: template, to: clusters[rhs])
            }
            if let targetIndex {
                clusters[targetIndex].append(contentsOf: moving)
            } else {
                clusters.append(contentsOf: moving.map { [$0] })
                break
            }
        }
        return clusters
    }

    private func averageDistance(from template: MotionTemplate, to cluster: [MotionTemplate]) -> Double {
        guard !cluster.isEmpty else { return .infinity }
        return cluster
            .map { matcher.distance(template.samples, $0.samples) }
            .reduce(0.0, +) / Double(cluster.count)
    }

    private func areCompatibleKinds(_ lhs: MotionTokenKind, _ rhs: MotionTokenKind) -> Bool {
        if lhs == rhs { return true }
        switch (lhs, rhs) {
        case (.impulse, .sweep), (.sweep, .impulse),
             (.rotation, .oscillation), (.oscillation, .rotation),
             (.free, _), (_, .free):
            return true
        default:
            return false
        }
    }

    private func durationRatio(_ lhs: Double, _ rhs: Double) -> Double {
        let small = max(min(lhs, rhs), 0.0001)
        let large = max(lhs, rhs)
        return large / small
    }

    private func dominantAxis(_ template: MotionTemplate) -> Int {
        template.features?.dominantAxis ?? MotionEnergyAnalyzer().features(for: template.samples).dominantAxis
    }
}

public struct MotionRecognitionRouter: Sendable {
    public var tokenizer: MotionTokenizer
    public var extractor: MotionFeatureExtractor
    public var matcher: MotionTemplateMatcher
    public var activityTrimmer: MotionSampleActivityTrimmer
    public var stageExtractor: MotionStageExtractor
    public var poseAnalyzer: MotionPoseAnalyzer

    public init(
        tokenizer: MotionTokenizer = MotionTokenizer(),
        extractor: MotionFeatureExtractor = MotionFeatureExtractor(),
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        activityTrimmer: MotionSampleActivityTrimmer = MotionSampleActivityTrimmer(),
        stageExtractor: MotionStageExtractor = MotionStageExtractor(),
        poseAnalyzer: MotionPoseAnalyzer = MotionPoseAnalyzer()
    ) {
        self.tokenizer = tokenizer
        self.extractor = extractor
        self.matcher = matcher
        self.activityTrimmer = activityTrimmer
        self.stageExtractor = stageExtractor
        self.poseAnalyzer = poseAnalyzer
    }

    public func evaluate(
        segment: GestureSegment,
        profiles: [GestureProfile],
        lastTriggerTimes: [UUID: Double] = [:],
        now: Double? = nil,
        burstGate: MotionBurstGate = MotionBurstGate()
    ) -> RoutedRecognitionEvaluation {
        let tokens = tokenizer.tokenize(segment: segment)
        let classifiedKind = dominantToken(in: tokens)?.kind ?? .free
        var reports: [CandidateRecognitionReport] = []
        var candidates: [RecognitionCandidate] = []
        var firstBurstGateReason: BurstGateRejectionReason?

        for profile in profiles {
            if let now, let last = lastTriggerTimes[profile.id], now - last < profile.cooldownSeconds {
                reports.append(report(profile: profile, kind: classifiedKind, score: 0, reason: .cooldownActive))
                continue
            }

            let gateDecision = burstGate.decision(for: segment, profile: profile)
            guard gateDecision.isAllowed else {
                if firstBurstGateReason == nil {
                    firstBurstGateReason = gateDecision.reason
                }
                reports.append(report(profile: profile, kind: classifiedKind, score: 0, reason: rejectReason(for: gateDecision.reason)))
                continue
            }

            guard let result = trajectoryScore(profile: profile, segment: segment, tokens: tokens) else {
                reports.append(report(profile: profile, kind: classifiedKind, score: 0, reason: .scoreBelowThreshold))
                continue
            }

            reports.append(result.report)
            candidates.append(result.candidate)
        }

        let sortedCandidates = candidates.sorted {
            competitionScore(for: $0) > competitionScore(for: $1)
        }
        var best = sortedCandidates.first
        if let bestCandidate = best {
            let second = sortedCandidates.dropFirst().first(where: { isMarginCompetitor($0) })
            if let second {
                let bestScore = competitionScore(for: bestCandidate)
                let secondScore = competitionScore(for: second)
                let scoreMargin = bestScore - secondScore
                best?.margin = scoreMargin
                best?.secondBestDistance = second.distance

                let requiredMargin: Double
                if bestCandidate.recognitionScore != nil, let thresholds = bestCandidate.profile.thresholds {
                    requiredMargin = thresholds.marginScore
                } else {
                    requiredMargin = max(
                        bestCandidate.profile.marginThreshold,
                        bestCandidate.profile.thresholds?.marginScore ?? 0
                    )
                }

                if scoreMargin < requiredMargin {
                    best?.rejectReason = .marginTooSmall
                }
            } else {
                best?.margin = nil
            }
        }

        let accepted = best.flatMap { candidate -> RecognitionCandidate? in
            candidate.shouldTrigger ? candidate : candidate
        }
        let rejectReason = decisionRejectReason(best: accepted, reports: reports)

        return RoutedRecognitionEvaluation(
            candidate: accepted,
            tokens: tokens,
            classifiedKind: classifiedKind,
            candidateReports: reports,
            rejectReason: accepted?.shouldTrigger == true ? nil : rejectReason,
            burstGateRejectionReason: firstBurstGateReason
        )
    }

    private func dominantToken(in tokens: [MotionToken]) -> MotionToken? {
        tokens
            .filter { $0.kind != .pause }
            .max {
                let lhs = $0.confidence * max(0.25, $0.magnitude)
                let rhs = $1.confidence * max(0.25, $1.magnitude)
                return lhs < rhs
            }
            ?? tokens.first
    }

    private func trajectoryScore(
        profile: GestureProfile,
        segment: GestureSegment,
        tokens: [MotionToken]
    ) -> (candidate: RecognitionCandidate, report: CandidateRecognitionReport)? {
        let variants = scoringVariants(for: profile)
        if variants.count > 1 || variants.first?.variant != nil {
            return variants
                .compactMap { scoringVariant in
                    trajectoryScoreForVariant(
                        profile: scoringVariant.profile,
                        segment: segment,
                        tokens: tokens,
                        variant: scoringVariant.variant
                    )
                }
                .max {
                    ($0.candidate.recognitionScore ?? $0.candidate.confidence) <
                        ($1.candidate.recognitionScore ?? $1.candidate.confidence)
                }
        }
        return trajectoryScoreForVariant(profile: profile, segment: segment, tokens: tokens, variant: nil)
    }

    private func scoringVariants(
        for profile: GestureProfile
    ) -> [(variant: GestureProfileVariant?, profile: GestureProfile)] {
        guard let variants = profile.signatureVariants?.filter({ !$0.templateIDs.isEmpty }),
              !variants.isEmpty else {
            return [(nil, profile)]
        }

        return variants.map { variant in
            var scopedProfile = profile
            let templateIDSet = Set(variant.templateIDs)
            let scopedTemplates = profile.templates.filter { templateIDSet.contains($0.id) }
            if !scopedTemplates.isEmpty {
                scopedProfile.templates = scopedTemplates
            }
            var scopedSignature = variant.signature
            if scopedSignature.pose == nil {
                scopedSignature.pose = profile.signature?.pose
            }
            if scopedSignature.stages == nil {
                scopedSignature.stages = profile.signature?.stages
            }
            scopedProfile.signature = scopedSignature
            scopedProfile.thresholds = variant.thresholds
            scopedProfile.acceptanceThreshold = variant.acceptanceThreshold
            scopedProfile.marginThreshold = variant.marginThreshold
            scopedProfile.quality = variant.quality
            return (variant, scopedProfile)
        }
    }

    private func trajectoryScoreForVariant(
        profile: GestureProfile,
        segment: GestureSegment,
        tokens: [MotionToken],
        variant: GestureProfileVariant?
    ) -> (candidate: RecognitionCandidate, report: CandidateRecognitionReport)? {
        let matchingSegment = trimmedSegment(segment, for: profile)
        let matchingTokens = tokenizer.tokenize(
            segment: matchingSegment,
            calibration: profile.signature?.tokenizerCalibration
        )
        guard var match = matcher.bestMatch(
            profiles: [profile],
            candidateSamples: matchingSegment.samples
        ) else {
            return nil
        }

        let tokenScore = profile.signature.map {
            score(profile: profile, signature: $0, segment: matchingSegment, tokens: matchingTokens)
        }
        let stageScore = stageExtractor.match(signature: profile.signature?.stages, samples: matchingSegment.samples)
        let poseScore = poseAnalyzer.match(signature: profile.signature?.pose, samples: matchingSegment.samples)
        let kind = tokenScore?.candidate.recognizerKind ?? explanatoryKind(
            profile: profile,
            segment: matchingSegment,
            tokens: matchingTokens
        )
        let rejectReason = trajectoryRejectReason(
            profile: profile,
            segment: matchingSegment,
            tokens: matchingTokens,
            match: match,
            stageScore: stageScore,
            poseScore: poseScore
        )
        match.margin = nil
        if profile.signature != nil {
            let trajectoryScore = trajectoryTriggerScore(
                distance: match.distance,
                threshold: profile.acceptanceThreshold,
                triggerScore: profile.thresholds?.triggerScore
            )
            let semanticScore = tokenScore?.candidate.recognitionScore ?? tokenScore?.candidate.confidence
            match.recognitionScore = trajectoryTriggerScore(
                trajectoryScore: trajectoryScore,
                semanticScore: semanticScore,
                stageScore: stageScore?.score,
                poseScore: poseScore?.score,
                poseConfidence: profile.signature?.pose?.confidence ?? 0,
                stageCount: profile.signature?.stages?.count ?? 0,
                recognizerKind: tokenScore?.candidate.recognizerKind,
                policy: profile.thresholds?.fusionPolicy ?? profile.signature?.fusionPolicy
            )
        }
        if let rejectReason {
            match.rejectReason = rejectReason
        }
        if let rejectReason, isHardCompetitionReject(rejectReason) {
            let cappedScore = min(
                match.recognitionScore ?? match.confidence,
                hardRejectScoreCap(for: rejectReason)
            )
            match.recognitionScore = cappedScore
            match.confidence = min(match.confidence, cappedScore)
        }
        match.recognizerKind = kind
        match.variantID = variant?.id
        match.variantLabel = variant?.label

        let scoreThreshold = profile.thresholds?.triggerScore ?? (1 - profile.acceptanceThreshold)
        let report = CandidateRecognitionReport(
            profileID: profile.id,
            profileName: profile.name,
            variantID: variant?.id,
            variantLabel: variant?.label,
            recognizerKind: kind,
            score: match.recognitionScore ?? match.confidence,
            threshold: scoreThreshold,
            margin: match.margin,
            shouldTrigger: match.shouldTrigger,
            rejectReason: match.shouldTrigger ? nil : (rejectReason ?? .scoreBelowThreshold)
        )
        return (match, report)
    }

    private func trimmedSegment(_ segment: GestureSegment, for profile: GestureProfile) -> GestureSegment {
        let kind = trimmingKind(for: profile)
        let samples = profile.signature?.pose == nil
            ? activityTrimmer.trimForTemplate(
                segment.samples,
                requestedKind: kind,
                strategy: trimStrategy(for: profile)
            )
            : segment.samples
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else {
            return segment
        }
        let features = MotionEnergyAnalyzer().features(for: samples)
        let frames = MotionEnergyAnalyzer().frames(for: samples)
        let peakFrame = frames.max(by: { $0.energy < $1.energy })
        let segmentKind: GestureKind
        switch kind {
        case .posture:
            segmentKind = .posture
        case .combo:
            segmentKind = .combo
        case .sequence:
            segmentKind = .sequence
        case .burst:
            segmentKind = features.duration <= 1.6 ? .burst : .sequence
        }
        return GestureSegment(
            id: segment.id,
            kind: segmentKind,
            samples: samples,
            startTimestamp: first.timestamp,
            endTimestamp: last.timestamp,
            peakTimestamp: peakFrame?.timestamp ?? segment.peakTimestamp,
            peakEnergy: peakFrame?.energy ?? segment.peakEnergy,
            features: features
        )
    }

    private func trimmingKind(for profile: GestureProfile) -> GestureKind {
        guard let primaryKind = profile.signature?.primaryKind else {
            return profile.kind
        }
        switch primaryKind {
        case .impulse, .sweep:
            return .burst
        case .rotation, .oscillation:
            return .sequence
        case .hold:
            return .posture
        case .pause, .free:
            return profile.kind
        }
    }

    private func trimStrategy(for profile: GestureProfile) -> TrimStrategy? {
        guard let primaryKind = profile.signature?.primaryKind else {
            return nil
        }
        switch primaryKind {
        case .impulse:
            if profile.signature?.pose != nil {
                return .fullActiveWindow
            }
            return .impulsePeakWindow
        case .rotation:
            return .rotationAngleWindow
        case .oscillation:
            return .oscillationCycleWindow
        case .hold:
            return .holdStableWindow
        case .sweep, .pause, .free:
            return .fullActiveWindow
        }
    }

    private func explanatoryKind(profile: GestureProfile, segment: GestureSegment, tokens: [MotionToken]) -> MotionTokenKind {
        let token = dominantToken(in: tokens)
        guard let signature = profile.signature else {
            return token?.kind ?? .free
        }
        return routeKind(signature: signature, token: token, features: extractor.extract(segment.samples))
    }

    private func trajectoryRejectReason(
        profile: GestureProfile,
        segment: GestureSegment,
        tokens: [MotionToken],
        match: RecognitionCandidate,
        stageScore: MotionStageMatchResult?,
        poseScore: MotionPoseMatchResult?
    ) -> RejectReason? {
        if let signature = profile.signature {
            let tokenResult = score(profile: profile, signature: signature, segment: segment, tokens: tokens)
            if let hardRejectReason = hardTrajectoryVetoReason(tokenResult.candidate.rejectReason) {
                return hardRejectReason
            }
            let semanticScore = tokenResult.candidate.recognitionScore ?? tokenResult.candidate.confidence
            let minimumSemanticScore = profile.thresholds?.rejectScore ?? 0.42
            let rotationSemanticPass = signature.rotation != nil
                && tokenResult.candidate.recognizerKind == .rotation
                && semanticScore >= minimumSemanticScore
            if !rotationSemanticPass {
                if let hardRejectReason = hardTrajectoryVetoReason(stageScore?.rejectReason) {
                    return hardRejectReason
                }
                if let hardRejectReason = hardTrajectoryVetoReason(poseScore?.rejectReason) {
                    return hardRejectReason
                }
            }
            let completeTrajectoryPass = match.distance <= profile.acceptanceThreshold
            let completeTrajectoryScore = trajectoryTriggerScore(
                distance: match.distance,
                threshold: profile.acceptanceThreshold,
                triggerScore: profile.thresholds?.triggerScore
            )
            if completeTrajectoryPass,
               completeTrajectoryScore >= (profile.thresholds?.triggerScore ?? 0.68),
               signature.primaryKind == .free || signature.primaryKind == .sweep {
                return nil
            }
            if match.distance > profile.acceptanceThreshold {
                let distanceRatio = match.distance / max(profile.acceptanceThreshold, 0.0001)
                let policy = profile.thresholds?.fusionPolicy ?? profile.signature?.fusionPolicy
                let maxSoftRatio = policy?.maxSoftDistanceRatio ?? (rotationSemanticPass ? 2.25 : 1.30)
                let softDistanceAllowed = distanceRatio <= maxSoftRatio && semanticScore >= minimumSemanticScore
                if !softDistanceAllowed {
                    return .trajectoryDistanceTooHigh
                }
            }
            if semanticScore < minimumSemanticScore {
                return tokenResult.candidate.rejectReason ?? .scoreBelowThreshold
            }
            if let stageScore, stageScore.score < 0.38 {
                return stageScore.rejectReason ?? .stageMismatch
            }
            let poseRejectScore = (profile.signature?.pose?.confidence ?? 0) >= 0.62 ? 0.48 : 0.30
            if let poseScore, poseScore.score < poseRejectScore {
                return poseScore.rejectReason ?? .poseMismatch
            }
        } else if match.distance > profile.acceptanceThreshold {
            return .scoreBelowThreshold
        }
        return nil
    }

    private func trajectoryTriggerScore(distance: Double, threshold: Double, triggerScore: Double?) -> Double {
        guard threshold > 0 else { return 0 }
        let floor = triggerScore ?? 0.68
        let normalizedDistance = max(0, distance / threshold)
        return clamp(1 - normalizedDistance * (1 - floor))
    }

    private func trajectoryTriggerScore(
        trajectoryScore: Double,
        semanticScore: Double?,
        stageScore: Double?,
        poseScore: Double?,
        poseConfidence: Double,
        stageCount: Int,
        recognizerKind: MotionTokenKind?,
        policy: RecognitionFusionPolicy?
    ) -> Double {
        let trajectoryWeight = policy?.trajectoryWeight ?? (recognizerKind == .rotation ? 0.24 : 0.52)
        let semanticWeight = policy?.semanticWeight ?? (recognizerKind == .rotation ? 0.48 : 0.26)
        var weightedScores: [(weight: Double, score: Double)] = [
            (trajectoryWeight, trajectoryScore)
        ]
        if let semanticScore {
            weightedScores.append((semanticWeight, semanticScore))
        }
        if let stageScore {
            let weight = policy?.stageWeight ?? (stageCount > 1 ? 0.17 : 0.10)
            weightedScores.append((weight, stageScore))
        }
        if let poseScore {
            let weight = policy?.poseWeight ?? (poseConfidence >= 0.62 ? 0.18 : 0.10)
            weightedScores.append((weight, poseScore))
        }
        let totalWeight = weightedScores.map(\.weight).reduce(0.0, +)
        guard totalWeight > 0 else { return 0 }
        return clamp(weightedScores.map { $0.weight * $0.score }.reduce(0.0, +) / totalWeight)
    }

    private func hardTrajectoryVetoReason(_ rejectReason: RejectReason?) -> RejectReason? {
        switch rejectReason {
        case .rotationAngleTooSmall,
             .rotationAxisUnstable,
             .rotationDirectionMismatch,
             .oscillationCountTooLow,
             .holdTooShort,
             .holdNotStable,
             .poseMismatch,
             .stageMismatch:
            return rejectReason
        case .none,
             .noCandidate,
             .segmentTooShort,
             .segmentTooLong,
             .lowEnergy,
             .typeMismatch,
             .impulsePeakTooWeak,
             .impulseDirectionMismatch,
             .oscillationNotPeriodic,
             .scoreBelowThreshold,
             .marginTooSmall,
             .cooldownActive,
             .audioMissing,
             .noActiveProfile:
            return nil
        case .trajectoryDistanceTooHigh:
            return rejectReason
        }
    }

    private func competitionScore(for candidate: RecognitionCandidate) -> Double {
        let score = candidate.recognitionScore ?? candidate.confidence
        guard let rejectReason = candidate.rejectReason,
              isHardCompetitionReject(rejectReason) else {
            return score
        }
        return min(score, hardRejectScoreCap(for: rejectReason))
    }

    private func isMarginCompetitor(_ candidate: RecognitionCandidate) -> Bool {
        guard let rejectReason = candidate.rejectReason else {
            return true
        }
        return !isHardCompetitionReject(rejectReason)
    }

    private func isHardCompetitionReject(_ rejectReason: RejectReason) -> Bool {
        switch rejectReason {
        case .trajectoryDistanceTooHigh,
             .poseMismatch,
             .stageMismatch,
             .typeMismatch,
             .impulseDirectionMismatch,
             .rotationAngleTooSmall,
             .rotationDirectionMismatch,
             .rotationAxisUnstable,
             .oscillationCountTooLow,
             .oscillationNotPeriodic,
             .holdNotStable,
             .holdTooShort:
            return true
        case .noCandidate,
             .segmentTooShort,
             .segmentTooLong,
             .lowEnergy,
             .impulsePeakTooWeak,
             .scoreBelowThreshold,
             .marginTooSmall,
             .cooldownActive,
             .audioMissing,
             .noActiveProfile:
            return false
        }
    }

    private func hardRejectScoreCap(for rejectReason: RejectReason) -> Double {
        switch rejectReason {
        case .trajectoryDistanceTooHigh:
            return 0.34
        case .poseMismatch, .stageMismatch:
            return 0.32
        case .rotationAngleTooSmall,
             .rotationDirectionMismatch,
             .rotationAxisUnstable,
             .oscillationCountTooLow,
             .oscillationNotPeriodic,
             .holdNotStable,
             .holdTooShort:
            return 0.30
        case .typeMismatch, .impulseDirectionMismatch:
            return 0.25
        case .noCandidate,
             .segmentTooShort,
             .segmentTooLong,
             .lowEnergy,
             .impulsePeakTooWeak,
             .scoreBelowThreshold,
             .marginTooSmall,
             .cooldownActive,
             .audioMissing,
             .noActiveProfile:
            return 1.0
        }
    }

    private func score(
        profile: GestureProfile,
        signature: GestureSignature,
        segment: GestureSegment,
        tokens: [MotionToken]
    ) -> (candidate: RecognitionCandidate, report: CandidateRecognitionReport) {
        let token = dominantToken(in: tokens)
        let features = extractor.extract(segment.samples)
        let kind = routeKind(signature: signature, token: token, features: features)
        let score: Double
        let rejectReason: RejectReason?

        if isHardTypeMismatch(signature: signature, token: token, routedKind: kind, features: features) {
            return makeCandidateAndReport(
                profile: profile,
                kind: kind,
                score: 0.25,
                rejectReason: .typeMismatch
            )
        }

        switch kind {
        case .impulse:
            if let primitive = primitiveScore(kind: .impulse, features: features, signature: signature) {
                (score, rejectReason) = (primitive.score, primitive.rejectReason)
            } else {
                (score, rejectReason) = (0, .typeMismatch)
            }
        case .rotation:
            if let primitive = primitiveScore(kind: .rotation, features: features, signature: signature) {
                (score, rejectReason) = (primitive.score, primitive.rejectReason)
            } else {
                (score, rejectReason) = (0, .typeMismatch)
            }
        case .oscillation:
            if let primitive = primitiveScore(kind: .oscillation, features: features, signature: signature) {
                (score, rejectReason) = (primitive.score, primitive.rejectReason)
            } else {
                (score, rejectReason) = (0, .typeMismatch)
            }
        case .hold:
            if let primitive = primitiveScore(kind: .hold, features: features, signature: signature) {
                (score, rejectReason) = (primitive.score, primitive.rejectReason)
            } else {
                (score, rejectReason) = (0, .typeMismatch)
            }
        case .sweep, .pause, .free:
            (score, rejectReason) = fallbackScore(profile: profile, samples: segment.samples)
        }

        return makeCandidateAndReport(
            profile: profile,
            kind: kind,
            score: score,
            rejectReason: rejectReason
        )
    }

    private func primitiveScore(
        kind: MotionTokenKind,
        features: GestureSampleFeatures,
        signature: GestureSignature
    ) -> PrimitiveRecognitionResult? {
        switch kind {
        case .impulse:
            return signature.impulse.map { ImpulsePrimitiveRecognizer().score(features: features, signature: $0) }
        case .rotation:
            return signature.rotation.map { RotationPrimitiveRecognizer().score(features: features, signature: $0) }
        case .oscillation:
            return signature.oscillation.map { OscillationPrimitiveRecognizer().score(features: features, signature: $0) }
        case .hold:
            return signature.hold.map { HoldPrimitiveRecognizer().score(features: features, signature: $0) }
        case .sweep, .pause, .free:
            return nil
        }
    }

    private func makeCandidateAndReport(
        profile: GestureProfile,
        kind: MotionTokenKind,
        score: Double,
        rejectReason: RejectReason?
    ) -> (candidate: RecognitionCandidate, report: CandidateRecognitionReport) {
        let threshold = profile.thresholds?.triggerScore ?? 0.68
        let distance = 1 - score
        let candidate = RecognitionCandidate(
            profile: profile,
            distance: distance,
            secondBestDistance: nil,
            margin: nil,
            confidence: score,
            templateID: profile.templates.first?.id ?? UUID(),
            recognitionScore: score,
            recognizerKind: kind,
            rejectReason: score >= threshold ? nil : (rejectReason ?? .scoreBelowThreshold)
        )
        let report = CandidateRecognitionReport(
            profileID: profile.id,
            profileName: profile.name,
            recognizerKind: kind,
            score: score,
            threshold: threshold,
            shouldTrigger: candidate.shouldTrigger,
            rejectReason: candidate.shouldTrigger ? nil : (rejectReason ?? .scoreBelowThreshold)
        )
        return (candidate, report)
    }

    private func routeKind(
        signature: GestureSignature,
        token: MotionToken?,
        features: GestureSampleFeatures? = nil
    ) -> MotionTokenKind {
        guard let token else { return signature.primaryKind }
        if signature.rotation != nil,
           (token.kind == .oscillation || token.kind == .free) {
            return .rotation
        }
        if token.kind == signature.primaryKind || signature.secondaryKinds.contains(token.kind) {
            return token.kind
        }
        if signature.primaryKind == .free {
            return .free
        }
        if token.kind == .free {
            if signature.rotation != nil {
                return .free
            }
            return signature.primaryKind
        }
        if token.kind == .impulse, signature.impulse != nil {
            return .impulse
        }
        if token.kind == .hold, signature.hold != nil {
            return .hold
        }
        return signature.primaryKind
    }

    private func isHardTypeMismatch(
        signature: GestureSignature,
        token: MotionToken?,
        routedKind: MotionTokenKind,
        features: GestureSampleFeatures
    ) -> Bool {
        guard let token else { return false }
        guard token.kind != .free else { return false }
        guard token.kind != signature.primaryKind, !signature.secondaryKinds.contains(token.kind) else {
            return false
        }

        switch (signature.primaryKind, token.kind) {
        case (.impulse, .sweep), (.sweep, .impulse):
            return false
        case (.rotation, .oscillation):
            let requiredAngle = signature.rotation.map { max(.pi * 0.75, $0.totalAngleRadians * 0.70) } ?? .pi
            return features.integratedRotationAngle < requiredAngle
        case (.rotation, .free):
            let requiredAngle = signature.rotation.map { max(.pi * 0.75, $0.totalAngleRadians * 0.45) } ?? .pi
            return features.integratedRotationAngle < requiredAngle
        case (.oscillation, .impulse):
            return signature.impulse == nil
        case (.impulse, .rotation), (.impulse, .oscillation), (.rotation, .impulse):
            return true
        case (.hold, _):
            return token.kind != .hold
        default:
            return routedKind != token.kind
        }
    }

    private func impulseScore(features: GestureSampleFeatures, signature: ImpulseSignature?) -> (Double, RejectReason?) {
        guard let signature else { return (0, .typeMismatch) }
        guard features.peakAcc >= max(0.18, signature.peakAcc * 0.22) || features.peakGyro >= max(0.4, signature.peakGyro * 0.22) else {
            return (0.2, .impulsePeakTooWeak)
        }
        let peakScore = ratioScore(value: features.peakAcc, reference: signature.peakAcc, lower: 0.25, upper: 2.4)
        let gyroScore = ratioScore(value: features.peakGyro, reference: signature.peakGyro, lower: 0.22, upper: 2.8)
        let durationScore = ratioScore(value: features.duration, reference: signature.duration, lower: 0.45, upper: 1.85)
        let directionScore = features.signedRotationAngle.sign == signature.direction.sign ? 1.0 : 0.55
        let score = peakScore * 0.30 + gyroScore * 0.22 + durationScore * 0.23 + directionScore * 0.25
        return (clamp(score), score >= 0.55 ? nil : .scoreBelowThreshold)
    }

    private func rotationScore(features: GestureSampleFeatures, signature: RotationSignature?) -> (Double, RejectReason?) {
        guard let signature else { return (0, .typeMismatch) }
        let minAngle = max(.pi * 0.65, signature.totalAngleRadians * 0.68)
        guard features.integratedRotationAngle >= minAngle else {
            return (0.25, .rotationAngleTooSmall)
        }
        let consistency = features.rotationDirectionConsistency
        guard consistency >= 0.42 else {
            return (0.35, .rotationDirectionMismatch)
        }
        let angleScore = ratioScore(value: features.integratedRotationAngle, reference: signature.totalAngleRadians, lower: 0.48, upper: 1.85)
        let axisAlignment = abs(dot(features.dominantRotationAxis, signature.axis))
        let axisScore = clamp(features.rotationAxisStability / max(signature.axisStability * 0.75, 0.25)) * axisAlignment
        let durationScore = ratioScore(value: features.duration, reference: signature.duration, lower: 0.35, upper: 2.6)
        let directionScore = features.signedRotationAngle.sign == signature.direction.sign ? 1.0 : 0.60
        let speedScore = ratioScore(value: features.meanGyro, reference: max(signature.angularSpeedMean, 0.05), lower: 0.20, upper: 3.4)
        let consistencyScore = ratioScore(value: consistency, reference: 0.82, lower: 0.50, upper: 1.22)
        let score = angleScore * 0.24
            + axisScore * 0.23
            + durationScore * 0.11
            + directionScore * 0.12
            + speedScore * 0.10
            + consistencyScore * 0.20
        let reason: RejectReason? = axisScore < 0.45
            ? .rotationAxisUnstable
            : (score >= 0.55 ? nil : .scoreBelowThreshold)
        return (clamp(score), reason)
    }

    private func oscillationScore(features: GestureSampleFeatures, signature: OscillationSignature?) -> (Double, RejectReason?) {
        guard let signature else { return (0, .typeMismatch) }
        guard features.oscillationCount >= max(0.5, signature.count * 0.45) else {
            return (0.25, .oscillationCountTooLow)
        }
        let countScore = ratioScore(value: features.oscillationCount, reference: signature.count, lower: 0.45, upper: 1.9)
        let periodicityScore = clamp(features.periodicityScore / max(signature.periodicityScore * 0.75, 0.2))
        let durationScore = ratioScore(value: features.duration, reference: signature.duration, lower: 0.45, upper: 2.2)
        let magnitudeScore = ratioScore(value: features.peakGyro, reference: signature.magnitude, lower: 0.25, upper: 2.8)
        let score = countScore * 0.34 + periodicityScore * 0.28 + durationScore * 0.18 + magnitudeScore * 0.20
        let reason: RejectReason? = periodicityScore < 0.42 ? .oscillationNotPeriodic : (score >= 0.55 ? nil : .scoreBelowThreshold)
        return (clamp(score), reason)
    }

    private func holdScore(features: GestureSampleFeatures, signature: HoldSignature?) -> (Double, RejectReason?) {
        guard let signature else { return (0, .typeMismatch) }
        guard features.holdDuration >= max(0.25, signature.duration * 0.55) else {
            return (0.25, .holdTooShort)
        }
        let stabilityScore = clamp(features.holdStability / max(signature.stability * 0.80, 0.2))
        let durationScore = ratioScore(value: features.duration, reference: signature.duration, lower: 0.55, upper: 1.8)
        let gyroScore = 1 - clamp(features.meanGyro / max(signature.meanGyro * 2.2, 0.2))
        let score = stabilityScore * 0.45 + durationScore * 0.30 + gyroScore * 0.25
        return (clamp(score), score >= 0.55 ? nil : .holdNotStable)
    }

    private func fallbackScore(profile: GestureProfile, samples: [MotionSample]) -> (Double, RejectReason?) {
        guard let match = matcher.bestMatch(profiles: [profile], candidateSamples: samples) else {
            return (0, .noCandidate)
        }
        return (match.confidence, match.shouldTrigger ? nil : .scoreBelowThreshold)
    }

    private func decisionRejectReason(best: RecognitionCandidate?, reports: [CandidateRecognitionReport]) -> RejectReason {
        guard let best else {
            return reports.first?.rejectReason ?? .noCandidate
        }
        if best.rejectReason == .cooldownActive {
            return .cooldownActive
        }
        if let threshold = best.profile.thresholds?.triggerScore,
           (best.recognitionScore ?? best.confidence) < threshold {
            return best.rejectReason ?? .scoreBelowThreshold
        }
        if let margin = best.margin,
           let marginScore = best.profile.thresholds?.marginScore,
           margin < marginScore {
            return .marginTooSmall
        }
        return best.rejectReason ?? .scoreBelowThreshold
    }

    private func report(
        profile: GestureProfile,
        kind: MotionTokenKind,
        score: Double,
        reason: RejectReason
    ) -> CandidateRecognitionReport {
        CandidateRecognitionReport(
            profileID: profile.id,
            profileName: profile.name,
            recognizerKind: kind,
            score: score,
            threshold: profile.thresholds?.triggerScore ?? 0.68,
            shouldTrigger: false,
            rejectReason: reason
        )
    }

    private func rejectReason(for burstReason: BurstGateRejectionReason?) -> RejectReason {
        switch burstReason {
        case .durationTooShort:
            return .segmentTooShort
        case .durationTooLong:
            return .segmentTooLong
        case .peakAccelerationTooLow:
            return .impulsePeakTooWeak
        case .peakRotationTooLow:
            return .lowEnergy
        case .dominantAxisMismatch:
            return .impulseDirectionMismatch
        case .kindMismatch:
            return .typeMismatch
        case nil:
            return .noCandidate
        }
    }

    private func ratioScore(value: Double, reference: Double, lower: Double, upper: Double) -> Double {
        guard reference > 0.0001 else { return value < 0.0001 ? 1 : 0 }
        let ratio = value / reference
        if ratio >= lower, ratio <= upper {
            let center = 1.0
            let spread = ratio < center ? center - lower : upper - center
            return clamp(1 - abs(ratio - center) / max(spread * 1.25, 0.0001))
        }
        if ratio < lower {
            return clamp(ratio / lower * 0.55)
        }
        return clamp(upper / ratio * 0.55)
    }
}

public struct RoutedRecognitionEvaluation: Equatable, Sendable {
    public var candidate: RecognitionCandidate?
    public var tokens: [MotionToken]
    public var classifiedKind: MotionTokenKind
    public var candidateReports: [CandidateRecognitionReport]
    public var rejectReason: RejectReason?
    public var burstGateRejectionReason: BurstGateRejectionReason?

    public init(
        candidate: RecognitionCandidate?,
        tokens: [MotionToken],
        classifiedKind: MotionTokenKind,
        candidateReports: [CandidateRecognitionReport],
        rejectReason: RejectReason?,
        burstGateRejectionReason: BurstGateRejectionReason?
    ) {
        self.candidate = candidate
        self.tokens = tokens
        self.classifiedKind = classifiedKind
        self.candidateReports = candidateReports
        self.rejectReason = rejectReason
        self.burstGateRejectionReason = burstGateRejectionReason
    }
}

private func dot(_ lhs: MotionVector3, _ rhs: MotionVector3) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}

private func average(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0.0, +) / Double(values.count)
}

private func averageVector(_ vectors: [MotionVector3]) -> MotionVector3 {
    guard !vectors.isEmpty else {
        return MotionVector3(x: 0, y: 0, z: -1)
    }
    return normalized(MotionVector3(
        x: average(vectors.map(\.x)),
        y: average(vectors.map(\.y)),
        z: average(vectors.map(\.z))
    ))
}

private func vectorConsistency(_ vectors: [MotionVector3], reference: MotionVector3) -> Double {
    guard !vectors.isEmpty else { return 0 }
    return average(vectors.map { vectorSimilarity($0, reference) })
}

private func vectorSimilarity(_ lhs: MotionVector3, _ rhs: MotionVector3) -> Double {
    guard lhs.magnitude > 0.0001, rhs.magnitude > 0.0001 else { return 0.5 }
    let value = dot(normalized(lhs), normalized(rhs))
    return clamp((max(-1, min(1, value)) + 1) * 0.5)
}

private func normalized(_ vector: MotionVector3) -> MotionVector3 {
    let magnitude = max(vector.magnitude, 0.0001)
    return MotionVector3(x: vector.x / magnitude, y: vector.y / magnitude, z: vector.z / magnitude)
}

private func ratioScore(value: Double, reference: Double, lower: Double, upper: Double) -> Double {
    guard reference > 0.0001 else { return value < 0.0001 ? 1 : 0 }
    let ratio = value / reference
    if ratio >= lower, ratio <= upper {
        let center = 1.0
        let spread = ratio < center ? center - lower : upper - center
        return clamp(1 - abs(ratio - center) / max(spread * 1.25, 0.0001))
    }
    if ratio < lower {
        return clamp(ratio / lower * 0.55)
    }
    return clamp(upper / ratio * 0.55)
}

private func clamp(_ value: Double) -> Double {
    max(0, min(1, value))
}
