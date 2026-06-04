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

public struct GestureSignature: Codable, Equatable, Sendable {
    public var primaryKind: MotionTokenKind
    public var secondaryKinds: [MotionTokenKind]
    public var tokenPatterns: [MotionTokenPattern]
    public var impulse: ImpulseSignature?
    public var rotation: RotationSignature?
    public var oscillation: OscillationSignature?
    public var hold: HoldSignature?
    public var fallbackTemplates: [NormalizedMotionTemplate]

    public init(
        primaryKind: MotionTokenKind,
        secondaryKinds: [MotionTokenKind] = [],
        tokenPatterns: [MotionTokenPattern] = [],
        impulse: ImpulseSignature? = nil,
        rotation: RotationSignature? = nil,
        oscillation: OscillationSignature? = nil,
        hold: HoldSignature? = nil,
        fallbackTemplates: [NormalizedMotionTemplate] = []
    ) {
        self.primaryKind = primaryKind
        self.secondaryKinds = secondaryKinds
        self.tokenPatterns = tokenPatterns
        self.impulse = impulse
        self.rotation = rotation
        self.oscillation = oscillation
        self.hold = hold
        self.fallbackTemplates = fallbackTemplates
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

    public init(
        triggerScore: Double = 0.68,
        rejectScore: Double = 0.45,
        marginScore: Double = 0.06,
        minEnergy: Double? = nil,
        minAngle: Double? = nil,
        minOscillationCount: Double? = nil,
        minHoldDuration: Double? = nil,
        strictness: Double = 0.5
    ) {
        self.triggerScore = triggerScore
        self.rejectScore = rejectScore
        self.marginScore = marginScore
        self.minEnergy = minEnergy
        self.minAngle = minAngle
        self.minOscillationCount = minOscillationCount
        self.minHoldDuration = minHoldDuration
        self.strictness = strictness
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
    public var recognizerKind: MotionTokenKind
    public var score: Double
    public var threshold: Double
    public var margin: Double?
    public var shouldTrigger: Bool
    public var rejectReason: RejectReason?

    public init(
        profileID: UUID,
        profileName: String,
        recognizerKind: MotionTokenKind,
        score: Double,
        threshold: Double,
        margin: Double? = nil,
        shouldTrigger: Bool,
        rejectReason: RejectReason? = nil
    ) {
        self.profileID = profileID
        self.profileName = profileName
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

    public init(energyAnalyzer: MotionEnergyAnalyzer = MotionEnergyAnalyzer()) {
        self.energyAnalyzer = energyAnalyzer
    }

    public func extract(_ samples: [MotionSample]) -> GestureSampleFeatures {
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
        let integratedSignedAngle = integrate(projectedGyro, samples: samples, absolute: false)
        let integratedAbsAngle = integrate(projectedGyro, samples: samples, absolute: true)
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

    private func dominantRotationAxis(_ samples: [MotionSample]) -> (axis: MotionVector3, stability: Double) {
        let totals = [
            samples.map { abs($0.rotationRate.x) }.reduce(0.0, +),
            samples.map { abs($0.rotationRate.y) }.reduce(0.0, +),
            samples.map { abs($0.rotationRate.z) }.reduce(0.0, +),
        ]
        let total = max(totals.reduce(0.0, +), 0.0001)
        let maxIndex = totals.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let sign = averageAxisSign(samples, axis: maxIndex)
        let axis: MotionVector3
        switch maxIndex {
        case 0:
            axis = MotionVector3(x: sign, y: 0, z: 0)
        case 1:
            axis = MotionVector3(x: 0, y: sign, z: 0)
        default:
            axis = MotionVector3(x: 0, y: 0, z: sign)
        }
        return (axis, totals[maxIndex] / total)
    }

    private func averageAxisSign(_ samples: [MotionSample], axis: Int) -> Double {
        let sum = samples.map { sample in
            switch axis {
            case 0: return sample.rotationRate.x
            case 1: return sample.rotationRate.y
            default: return sample.rotationRate.z
            }
        }.reduce(0.0, +)
        return sum >= 0 ? 1 : -1
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

    public init(extractor: MotionFeatureExtractor = MotionFeatureExtractor()) {
        self.extractor = extractor
    }

    public func tokenize(segment: GestureSegment) -> [MotionToken] {
        let features = extractor.extract(segment.samples)
        let kind = classify(features)
        let direction = features.signedRotationAngle >= 0 ? 1.0 : -1.0
        let magnitude = tokenMagnitude(kind: kind, features: features)
        let confidence = tokenConfidence(kind: kind, features: features)
        return [
            MotionToken(
                kind: kind,
                startTime: segment.startTimestamp,
                endTime: segment.endTimestamp,
                duration: segment.duration,
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
        ]
    }

    public func classify(_ features: GestureSampleFeatures) -> MotionTokenKind {
        if features.duration >= 0.35,
           features.holdStability >= 0.78,
           features.peakGyro < 0.45,
           features.peakAcc < 0.28 {
            return .hold
        }

        if (features.peakAcc >= 1.6 || features.peakJerk >= 32 || features.peakGyro >= 6.0),
           features.duration <= 2.2 {
            return .impulse
        }

        if features.zeroCrossingCount >= 3,
           features.periodicityScore >= 0.35,
           features.duration >= 0.45 {
            return .oscillation
        }

        if features.integratedRotationAngle >= .pi * 1.15,
           features.rotationAxisStability >= 0.55,
           features.zeroCrossingCount <= max(5, Int(features.duration * 2.5)),
           features.duration >= 0.45 {
            return .rotation
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

public struct GestureSignatureBuilder: Sendable {
    public var tokenizer: MotionTokenizer
    public var extractor: MotionFeatureExtractor

    public init(
        tokenizer: MotionTokenizer = MotionTokenizer(),
        extractor: MotionFeatureExtractor = MotionFeatureExtractor()
    ) {
        self.tokenizer = tokenizer
        self.extractor = extractor
    }

    public func makeSignature(templates: [MotionTemplate]) -> GestureSignature {
        let templateFeatures = templates.map { extractor.extract($0.samples) }
        let primary = primaryKind(features: templateFeatures)
        let secondary = secondaryKinds(features: templateFeatures, primary: primary)
        let patterns = templateFeatures.map {
            MotionTokenPattern(
                kind: tokenizer.classify($0),
                minDuration: max(0, $0.duration * 0.55),
                maxDuration: max($0.duration * 1.65, 0.25),
                expectedMagnitude: expectedMagnitude(kind: tokenizer.classify($0), features: $0)
            )
        }
        return GestureSignature(
            primaryKind: primary,
            secondaryKinds: secondary,
            tokenPatterns: patterns,
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
            base = templateCount >= 3 ? 0.66 : 0.70
        case .oscillation:
            base = templateCount >= 3 ? 0.64 : 0.69
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
            strictness: strictness
        )
    }

    private func primaryKind(features: [GestureSampleFeatures]) -> MotionTokenKind {
        let kinds = features.map { tokenizer.classify($0) }
        if let winner = Dictionary(grouping: kinds, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            return winner
        }
        return .free
    }

    private func secondaryKinds(features: [GestureSampleFeatures], primary: MotionTokenKind) -> [MotionTokenKind] {
        let kinds = Array(Set(features.map { tokenizer.classify($0) })).filter { $0 != primary }
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    private func makeImpulseSignature(features: [GestureSampleFeatures]) -> ImpulseSignature? {
        let impulses = features.filter { tokenizer.classify($0) == .impulse || $0.peakAcc >= 1.0 || $0.peakGyro >= 4.0 }
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
        let rotations = features.filter { tokenizer.classify($0) == .rotation || ($0.integratedRotationAngle >= .pi * 1.15 && $0.rotationAxisStability >= 0.55) }
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
        let oscillations = features.filter { tokenizer.classify($0) == .oscillation || $0.oscillationCount >= 1.5 }
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
        let holds = features.filter { tokenizer.classify($0) == .hold || $0.holdStability >= 0.78 }
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
}

public struct MotionRecognitionRouter: Sendable {
    public var tokenizer: MotionTokenizer
    public var extractor: MotionFeatureExtractor
    public var matcher: MotionTemplateMatcher
    public var activityTrimmer: MotionSampleActivityTrimmer

    public init(
        tokenizer: MotionTokenizer = MotionTokenizer(),
        extractor: MotionFeatureExtractor = MotionFeatureExtractor(),
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        activityTrimmer: MotionSampleActivityTrimmer = MotionSampleActivityTrimmer()
    ) {
        self.tokenizer = tokenizer
        self.extractor = extractor
        self.matcher = matcher
        self.activityTrimmer = activityTrimmer
    }

    public func evaluate(
        segment: GestureSegment,
        profiles: [GestureProfile],
        lastTriggerTimes: [UUID: Double] = [:],
        now: Double? = nil,
        burstGate: MotionBurstGate = MotionBurstGate()
    ) -> RoutedRecognitionEvaluation {
        let tokens = tokenizer.tokenize(segment: segment)
        let classifiedKind = tokens.first?.kind ?? .free
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
            ($0.recognitionScore ?? $0.confidence) > ($1.recognitionScore ?? $1.confidence)
        }
        var best = sortedCandidates.first
        if let bestCandidate = best {
            let second = sortedCandidates.dropFirst().first
            if let second {
                let bestScore = bestCandidate.recognitionScore ?? bestCandidate.confidence
                let secondScore = second.recognitionScore ?? second.confidence
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

    private func trajectoryScore(
        profile: GestureProfile,
        segment: GestureSegment,
        tokens: [MotionToken]
    ) -> (candidate: RecognitionCandidate, report: CandidateRecognitionReport)? {
        let matchingSegment = trimmedSegment(segment, for: profile)
        let matchingTokens = tokenizer.tokenize(segment: matchingSegment)
        guard var match = matcher.bestMatch(
            profiles: [profile],
            candidateSamples: matchingSegment.samples
        ) else {
            return nil
        }

        let tokenScore = profile.signature.map {
            score(profile: profile, signature: $0, segment: matchingSegment, tokens: matchingTokens)
        }
        let kind = tokenScore?.candidate.recognizerKind ?? explanatoryKind(profile: profile, tokens: matchingTokens)
        let rejectReason = trajectoryRejectReason(profile: profile, segment: matchingSegment, tokens: matchingTokens, match: match)
        match.margin = nil
        if profile.signature != nil {
            match.recognitionScore = trajectoryTriggerScore(
                distance: match.distance,
                threshold: profile.acceptanceThreshold,
                triggerScore: profile.thresholds?.triggerScore
            )
        }
        if let rejectReason {
            match.rejectReason = rejectReason
        }
        match.recognizerKind = kind

        let scoreThreshold = profile.thresholds?.triggerScore ?? (1 - profile.acceptanceThreshold)
        let report = CandidateRecognitionReport(
            profileID: profile.id,
            profileName: profile.name,
            recognizerKind: kind,
            score: match.recognitionScore ?? match.confidence,
            threshold: scoreThreshold,
            margin: match.margin,
            shouldTrigger: match.shouldTrigger,
            rejectReason: match.shouldTrigger ? nil : rejectReason
        )
        return (match, report)
    }

    private func trimmedSegment(_ segment: GestureSegment, for profile: GestureProfile) -> GestureSegment {
        let kind = trimmingKind(for: profile)
        let samples = activityTrimmer.trimForTemplate(segment.samples, requestedKind: kind)
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

    private func explanatoryKind(profile: GestureProfile, tokens: [MotionToken]) -> MotionTokenKind {
        let token = tokens.first
        guard let signature = profile.signature else {
            return token?.kind ?? .free
        }
        return routeKind(signature: signature, token: token)
    }

    private func trajectoryRejectReason(
        profile: GestureProfile,
        segment: GestureSegment,
        tokens: [MotionToken],
        match: RecognitionCandidate
    ) -> RejectReason? {
        if let signature = profile.signature {
            let tokenResult = score(profile: profile, signature: signature, segment: segment, tokens: tokens)
            if let hardRejectReason = hardTrajectoryVetoReason(tokenResult.candidate.rejectReason) {
                return hardRejectReason
            }
            if match.distance > profile.acceptanceThreshold {
                return tokenResult.candidate.rejectReason ?? .scoreBelowThreshold
            }
            let semanticScore = tokenResult.candidate.recognitionScore ?? tokenResult.candidate.confidence
            let minimumSemanticScore = profile.thresholds?.rejectScore ?? 0.42
            if semanticScore < minimumSemanticScore {
                return tokenResult.candidate.rejectReason ?? .scoreBelowThreshold
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

    private func hardTrajectoryVetoReason(_ rejectReason: RejectReason?) -> RejectReason? {
        switch rejectReason {
        case .rotationAngleTooSmall,
             .rotationAxisUnstable,
             .rotationDirectionMismatch,
             .oscillationCountTooLow,
             .holdTooShort,
             .holdNotStable:
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
             .audioMissing:
            return nil
        }
    }

    private func score(
        profile: GestureProfile,
        signature: GestureSignature,
        segment: GestureSegment,
        tokens: [MotionToken]
    ) -> (candidate: RecognitionCandidate, report: CandidateRecognitionReport) {
        let token = tokens.first
        let features = extractor.extract(segment.samples)
        let kind = routeKind(signature: signature, token: token)
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
            (score, rejectReason) = impulseScore(features: features, signature: signature.impulse)
        case .rotation:
            (score, rejectReason) = rotationScore(features: features, signature: signature.rotation)
        case .oscillation:
            (score, rejectReason) = oscillationScore(features: features, signature: signature.oscillation)
        case .hold:
            (score, rejectReason) = holdScore(features: features, signature: signature.hold)
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

    private func routeKind(signature: GestureSignature, token: MotionToken?) -> MotionTokenKind {
        guard let token else { return signature.primaryKind }
        if token.kind == signature.primaryKind || signature.secondaryKinds.contains(token.kind) {
            return token.kind
        }
        if signature.primaryKind == .free {
            return .free
        }
        if token.kind == .free {
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
        case (.rotation, .oscillation):
            let requiredAngle = signature.rotation.map { max(.pi * 0.75, $0.totalAngleRadians * 0.70) } ?? .pi
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
        let minAngle = max(.pi * 0.30, signature.totalAngleRadians * 0.45)
        guard features.integratedRotationAngle >= minAngle else {
            return (0.25, .rotationAngleTooSmall)
        }
        let angleScore = ratioScore(value: features.integratedRotationAngle, reference: signature.totalAngleRadians, lower: 0.48, upper: 1.85)
        let axisAlignment = abs(dot(features.dominantRotationAxis, signature.axis))
        let axisScore = clamp(features.rotationAxisStability / max(signature.axisStability * 0.75, 0.25)) * axisAlignment
        let durationScore = ratioScore(value: features.duration, reference: signature.duration, lower: 0.35, upper: 2.6)
        let directionScore = features.signedRotationAngle.sign == signature.direction.sign ? 1.0 : 0.60
        let speedScore = ratioScore(value: features.meanGyro, reference: max(signature.angularSpeedMean, 0.05), lower: 0.20, upper: 3.4)
        let score = angleScore * 0.30 + axisScore * 0.28 + durationScore * 0.13 + directionScore * 0.18 + speedScore * 0.11
        let reason: RejectReason? = axisScore < 0.45 ? .rotationAxisUnstable : (score >= 0.55 ? nil : .scoreBelowThreshold)
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

private func normalized(_ vector: MotionVector3) -> MotionVector3 {
    let magnitude = max(vector.magnitude, 0.0001)
    return MotionVector3(x: vector.x / magnitude, y: vector.y / magnitude, z: vector.z / magnitude)
}

private func clamp(_ value: Double) -> Double {
    max(0, min(1, value))
}
