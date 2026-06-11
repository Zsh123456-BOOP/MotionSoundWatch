import Foundation

public struct MotionRingBuffer: Equatable, Sendable {
    public var maxDuration: Double
    private var storage: [MotionSample]

    public init(maxDuration: Double) {
        self.maxDuration = maxDuration
        self.storage = []
    }

    public var samples: [MotionSample] {
        storage
    }

    public var count: Int {
        storage.count
    }

    public mutating func append(_ sample: MotionSample) {
        storage.append(sample)
        trim(relativeTo: sample.timestamp)
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }

    public func samples(from start: Double, through end: Double) -> [MotionSample] {
        storage.filter { $0.timestamp >= start && $0.timestamp <= end }
    }

    public func recent(seconds: Double, endingAt end: Double? = nil) -> [MotionSample] {
        guard let end = end ?? storage.last?.timestamp else { return [] }
        return samples(from: end - seconds, through: end)
    }

    private mutating func trim(relativeTo timestamp: Double) {
        let cutoff = timestamp - maxDuration
        storage.removeAll { $0.timestamp < cutoff }
    }
}

public struct MotionEnergyFrame: Equatable, Sendable {
    public var timestamp: Double
    public var accelerationMagnitude: Double
    public var rotationMagnitude: Double
    public var jerkMagnitude: Double
    public var energy: Double

    public init(
        timestamp: Double,
        accelerationMagnitude: Double,
        rotationMagnitude: Double,
        jerkMagnitude: Double,
        energy: Double
    ) {
        self.timestamp = timestamp
        self.accelerationMagnitude = accelerationMagnitude
        self.rotationMagnitude = rotationMagnitude
        self.jerkMagnitude = jerkMagnitude
        self.energy = energy
    }
}

public struct MotionEnergyAnalyzer: Sendable {
    public var rotationWeight: Double
    public var jerkWeight: Double

    public init(rotationWeight: Double = 0.25, jerkWeight: Double = 0.1) {
        self.rotationWeight = rotationWeight
        self.jerkWeight = jerkWeight
    }

    public func frame(for sample: MotionSample, previous: MotionSample?) -> MotionEnergyFrame {
        let accelerationMagnitude = sample.userAcceleration.magnitude
        let rotationMagnitude = sample.rotationRate.magnitude
        let jerkMagnitude: Double

        if let previous {
            let dt = max(sample.timestamp - previous.timestamp, .leastNonzeroMagnitude)
            jerkMagnitude = abs(accelerationMagnitude - previous.userAcceleration.magnitude) / dt
        } else {
            jerkMagnitude = 0
        }

        let energy = accelerationMagnitude + rotationWeight * rotationMagnitude + jerkWeight * jerkMagnitude
        return MotionEnergyFrame(
            timestamp: sample.timestamp,
            accelerationMagnitude: accelerationMagnitude,
            rotationMagnitude: rotationMagnitude,
            jerkMagnitude: jerkMagnitude,
            energy: energy
        )
    }

    public func frames(for samples: [MotionSample]) -> [MotionEnergyFrame] {
        var previous: MotionSample?
        return samples.map { sample in
            defer { previous = sample }
            return frame(for: sample, previous: previous)
        }
    }

    public func features(for samples: [MotionSample], energyShapeCount: Int = 16) -> GestureFeatures {
        let frames = frames(for: samples)
        guard !samples.isEmpty, !frames.isEmpty else {
            return GestureFeatures(
                duration: 0,
                peakAcceleration: 0,
                peakRotationRate: 0,
                peakJerk: 0,
                meanEnergy: 0,
                dominantAxis: 0,
                energyShape: []
            )
        }

        let duration = max(0, (samples.last?.timestamp ?? 0) - (samples.first?.timestamp ?? 0))
        let meanEnergy = frames.map(\.energy).reduce(0, +) / Double(frames.count)
        let dominantAxis = dominantAccelerationAxis(samples)

        return GestureFeatures(
            duration: duration,
            peakAcceleration: frames.map(\.accelerationMagnitude).max() ?? 0,
            peakRotationRate: frames.map(\.rotationMagnitude).max() ?? 0,
            peakJerk: frames.map(\.jerkMagnitude).max() ?? 0,
            meanEnergy: meanEnergy,
            dominantAxis: dominantAxis,
            energyShape: resampledEnergyShape(frames, targetCount: energyShapeCount)
        )
    }

    private func dominantAccelerationAxis(_ samples: [MotionSample]) -> Int {
        let axisPeaks: [Double] = [
            (samples.map { abs($0.userAcceleration.x) }.max() ?? 0),
            (samples.map { abs($0.userAcceleration.y) }.max() ?? 0),
            (samples.map { abs($0.userAcceleration.z) }.max() ?? 0),
        ]
        return axisPeaks.enumerated().max { $0.element < $1.element }?.offset ?? 0
    }

    private func resampledEnergyShape(_ frames: [MotionEnergyFrame], targetCount: Int) -> [Double] {
        guard frames.count > 1, targetCount > 1 else {
            return frames.map(\.energy)
        }

        let start = frames.first!.timestamp
        let end = frames.last!.timestamp
        let duration = max(end - start, .leastNonzeroMagnitude)
        let peak = max(frames.map(\.energy).max() ?? 1, 0.001)
        var output: [Double] = []
        output.reserveCapacity(targetCount)

        var sourceIndex = 0
        for index in 0..<targetCount {
            let t = start + duration * Double(index) / Double(targetCount - 1)
            while sourceIndex < frames.count - 2, frames[sourceIndex + 1].timestamp < t {
                sourceIndex += 1
            }

            let left = frames[sourceIndex]
            let right = frames[min(sourceIndex + 1, frames.count - 1)]
            let span = max(right.timestamp - left.timestamp, .leastNonzeroMagnitude)
            let alpha = max(0, min(1, (t - left.timestamp) / span))
            let energy = left.energy + (right.energy - left.energy) * alpha
            output.append(energy / peak)
        }

        return output
    }
}

public struct MotionSampleActivityTrimmer: Sendable {
    public var energyAnalyzer: MotionEnergyAnalyzer
    public var featureExtractor: MotionFeatureExtractor
    public var tokenizer: MotionTokenizer
    public var activePadding: Double
    public var peakWindowBefore: Double
    public var peakWindowAfter: Double

    public init(
        energyAnalyzer: MotionEnergyAnalyzer = MotionEnergyAnalyzer(),
        featureExtractor: MotionFeatureExtractor = MotionFeatureExtractor(),
        tokenizer: MotionTokenizer = MotionTokenizer(),
        activePadding: Double = 0.25,
        peakWindowBefore: Double = 0.25,
        peakWindowAfter: Double = 0.45
    ) {
        self.energyAnalyzer = energyAnalyzer
        self.featureExtractor = featureExtractor
        self.tokenizer = tokenizer
        self.activePadding = activePadding
        self.peakWindowBefore = peakWindowBefore
        self.peakWindowAfter = peakWindowAfter
    }

    public func trimForTemplate(
        _ samples: [MotionSample],
        requestedKind: GestureKind,
        strategy explicitStrategy: TrimStrategy? = nil
    ) -> [MotionSample] {
        guard samples.count >= 8,
              let firstSample = samples.first,
              let lastSample = samples.last else {
            return retimestamp(samples)
        }

        let frames = energyAnalyzer.frames(for: samples)
        let features = featureExtractor.extract(samples)
        let strategy = explicitStrategy ?? trimStrategy(requestedKind: requestedKind, features: features)
        switch strategy {
        case .rotationAngleWindow:
            return rotationAngleWindow(samples, features: features)
        case .oscillationCycleWindow:
            return oscillationCycleWindow(samples, features: features)
        case .holdStableWindow:
            return holdStableWindow(samples)
        case .fullActiveWindow:
            return fullActiveWindow(samples, frames: frames)
        case .impulsePeakWindow:
            break
        }

        guard let peakFrame = frames.max(by: { $0.energy < $1.energy }),
              peakFrame.energy >= 0.18 else {
            return retimestamp(samples)
        }

        let threshold = max(0.16, peakFrame.energy * 0.18)
        let activeFrames = frames.filter { $0.energy >= threshold }
        guard let firstActive = activeFrames.first,
              let lastActive = activeFrames.last else {
            return retimestamp(samples)
        }

        let originalDuration = max(0, lastSample.timestamp - firstSample.timestamp)
        let activeStart = max(firstSample.timestamp, firstActive.timestamp - activePadding)
        let activeEnd = min(lastSample.timestamp, lastActive.timestamp + activePadding)
        let activeSamples = clippedSamples(samples, start: activeStart, end: activeEnd)
        let activeDuration = duration(activeSamples)

        if shouldFocusOnPeak(
            requestedKind: requestedKind,
            originalDuration: originalDuration,
            activeDuration: activeDuration,
            activeSamples: activeSamples
        ) {
            return clippedSamples(
                samples,
                start: peakFrame.timestamp - peakWindowBefore,
                end: peakFrame.timestamp + peakWindowAfter
            )
        }

        return activeSamples
    }

    public func trimStrategy(requestedKind: GestureKind, features: GestureSampleFeatures) -> TrimStrategy {
        let classifiedKind = tokenizer.classify(features)
        switch requestedKind {
        case .burst:
            return classifiedKind == .impulse ? .impulsePeakWindow : .fullActiveWindow
        case .sequence:
            if classifiedKind == .rotation || features.integratedRotationAngle >= .pi * 0.55 {
                return .rotationAngleWindow
            }
            if classifiedKind == .oscillation || features.oscillationCount >= 1.5 {
                return .oscillationCycleWindow
            }
            return .fullActiveWindow
        case .posture:
            return .holdStableWindow
        case .combo:
            return .fullActiveWindow
        }
    }

    private func fullActiveWindow(_ samples: [MotionSample], frames: [MotionEnergyFrame]) -> [MotionSample] {
        guard let firstSample = samples.first,
              let lastSample = samples.last,
              let peakEnergy = frames.map(\.energy).max(),
              peakEnergy >= 0.04 else {
            return retimestamp(samples)
        }
        let threshold = max(0.035, peakEnergy * 0.12)
        let activeFrames = frames.filter { $0.energy >= threshold }
        guard let firstActive = activeFrames.first,
              let lastActive = activeFrames.last else {
            return retimestamp(samples)
        }
        return clippedSamples(
            samples,
            start: max(firstSample.timestamp, firstActive.timestamp - activePadding),
            end: min(lastSample.timestamp, lastActive.timestamp + activePadding)
        )
    }

    private func rotationAngleWindow(_ samples: [MotionSample], features: GestureSampleFeatures) -> [MotionSample] {
        guard samples.count >= 2,
              let firstSample = samples.first,
              let lastSample = samples.last else {
            return retimestamp(samples)
        }
        let axis = normalized(features.dominantRotationAxis)
        let projected = samples.map { dot($0.rotationRate, axis) }
        let totalAngle = cumulativeAngle(projected, samples: samples).last ?? 0
        guard totalAngle >= 0.15 else {
            return retimestamp(samples)
        }

        let cumulative = cumulativeAngle(projected, samples: samples)
        let startTarget = totalAngle * 0.06
        let endTarget = totalAngle * 0.94
        let startIndex = cumulative.firstIndex { $0 >= startTarget } ?? samples.startIndex
        let endIndex = cumulative.firstIndex { $0 >= endTarget } ?? samples.index(before: samples.endIndex)
        let start = max(firstSample.timestamp, samples[startIndex].timestamp - activePadding)
        let end = min(lastSample.timestamp, samples[endIndex].timestamp + activePadding)
        return clippedSamples(samples, start: start, end: end)
    }

    private func oscillationCycleWindow(_ samples: [MotionSample], features: GestureSampleFeatures) -> [MotionSample] {
        guard samples.count >= 2,
              let firstSample = samples.first,
              let lastSample = samples.last else {
            return retimestamp(samples)
        }
        let axis = normalized(features.dominantRotationAxis)
        let projected = samples.map { dot($0.rotationRate, axis) }
        let deadband = max(0.04, features.peakGyro * 0.08)
        var crossingIndices: [Int] = []
        var previousSign = 0
        for (index, value) in projected.enumerated() {
            let sign = sign(value, deadband: deadband)
            guard sign != 0 else { continue }
            if previousSign != 0, sign != previousSign {
                crossingIndices.append(index)
            }
            previousSign = sign
        }
        guard let firstCrossing = crossingIndices.first,
              let lastCrossing = crossingIndices.last else {
            return fullActiveWindow(samples, frames: energyAnalyzer.frames(for: samples))
        }
        return clippedSamples(
            samples,
            start: max(firstSample.timestamp, samples[firstCrossing].timestamp - 0.35),
            end: min(lastSample.timestamp, samples[lastCrossing].timestamp + 0.35)
        )
    }

    private func holdStableWindow(_ samples: [MotionSample]) -> [MotionSample] {
        guard samples.count >= 8,
              let firstSample = samples.first,
              let lastSample = samples.last else {
            return retimestamp(samples)
        }
        let frames = energyAnalyzer.frames(for: samples)
        let peakEnergy = frames.map(\.energy).max() ?? 0
        let stableThreshold = max(0.08, peakEnergy * 0.18)
        var currentStart: Int?
        for (index, frame) in frames.enumerated() {
            if frame.energy <= stableThreshold {
                if currentStart == nil { currentStart = index }
            } else {
                currentStart = nil
            }
        }
        guard let suffixStart = currentStart,
              lastSample.timestamp - samples[suffixStart].timestamp >= 0.35 else {
            return fullActiveWindow(samples, frames: frames)
        }
        let start = max(firstSample.timestamp, samples[suffixStart].timestamp - 0.20)
        return clippedSamples(samples, start: start, end: lastSample.timestamp)
    }

    private func shouldFocusOnPeak(
        requestedKind: GestureKind,
        originalDuration: Double,
        activeDuration: Double,
        activeSamples: [MotionSample]
    ) -> Bool {
        guard requestedKind == .burst else { return false }
        guard originalDuration > 3.0 || activeDuration > 2.2 else { return false }
        guard duration(activeSamples) > peakWindowBefore + peakWindowAfter else { return false }

        let features = featureExtractor.extract(activeSamples)
        return tokenizer.classify(features) == .impulse
            || features.peakAcc >= 1.6
            || features.peakGyro >= 6.0
            || features.peakJerk >= 32
    }

    private func clippedSamples(_ samples: [MotionSample], start: Double, end: Double) -> [MotionSample] {
        let clipped = samples.filter { $0.timestamp >= start && $0.timestamp <= end }
        if clipped.count >= 2 {
            return retimestamp(clipped)
        }
        return retimestamp(samples)
    }

    private func retimestamp(_ samples: [MotionSample]) -> [MotionSample] {
        guard let first = samples.first else { return [] }
        return samples.map { sample in
            MotionSample(
                timestamp: max(0, sample.timestamp - first.timestamp),
                userAcceleration: sample.userAcceleration,
                rotationRate: sample.rotationRate,
                gravity: sample.gravity,
                attitude: sample.attitude
            )
        }
    }

    private func duration(_ samples: [MotionSample]) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return max(0, last.timestamp - first.timestamp)
    }

    private func normalized(_ vector: MotionVector3) -> MotionVector3 {
        let magnitude = max(vector.magnitude, 0.0001)
        return MotionVector3(x: vector.x / magnitude, y: vector.y / magnitude, z: vector.z / magnitude)
    }

    private func dot(_ lhs: MotionVector3, _ rhs: MotionVector3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private func cumulativeAngle(_ values: [Double], samples: [MotionSample]) -> [Double] {
        guard values.count == samples.count, samples.count > 1 else { return Array(repeating: 0, count: samples.count) }
        var output = Array(repeating: 0.0, count: samples.count)
        for index in 1..<samples.count {
            let dt = max(0, samples[index].timestamp - samples[index - 1].timestamp)
            output[index] = output[index - 1] + abs((values[index] + values[index - 1]) * 0.5) * dt
        }
        return output
    }

    private func sign(_ value: Double, deadband: Double) -> Int {
        if value > deadband { return 1 }
        if value < -deadband { return -1 }
        return 0
    }
}

public enum GestureSegmenterState: String, Codable, Equatable, Sendable {
    case idle
    case candidateStarted
    case activeGesture
    case maybeEnding
    case cooldown
}

public struct GestureSegmenterConfiguration: Equatable, Sendable {
    public var ringBufferDuration: Double
    public var preRollDuration: Double
    public var postRollDuration: Double
    public var startEnergyThreshold: Double
    public var endEnergyThreshold: Double
    public var endConfirmationDuration: Double
    public var minimumGestureDuration: Double
    public var burstMaximumDuration: Double
    public var cooldownDuration: Double

    public init(
        ringBufferDuration: Double = 8,
        preRollDuration: Double = 0.25,
        postRollDuration: Double = 0.15,
        startEnergyThreshold: Double = 0.42,
        endEnergyThreshold: Double = 0.18,
        endConfirmationDuration: Double = 0.25,
        minimumGestureDuration: Double = 0.12,
        burstMaximumDuration: Double = 0.8,
        cooldownDuration: Double = 0.35
    ) {
        self.ringBufferDuration = ringBufferDuration
        self.preRollDuration = preRollDuration
        self.postRollDuration = postRollDuration
        self.startEnergyThreshold = startEnergyThreshold
        self.endEnergyThreshold = endEnergyThreshold
        self.endConfirmationDuration = endConfirmationDuration
        self.minimumGestureDuration = minimumGestureDuration
        self.burstMaximumDuration = burstMaximumDuration
        self.cooldownDuration = cooldownDuration
    }
}

public struct GestureSegment: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: GestureKind
    public var samples: [MotionSample]
    public var startTimestamp: Double
    public var endTimestamp: Double
    public var peakTimestamp: Double
    public var peakEnergy: Double
    public var features: GestureFeatures

    public var duration: Double {
        max(0, endTimestamp - startTimestamp)
    }

    public init(
        id: UUID = UUID(),
        kind: GestureKind,
        samples: [MotionSample],
        startTimestamp: Double,
        endTimestamp: Double,
        peakTimestamp: Double,
        peakEnergy: Double,
        features: GestureFeatures
    ) {
        self.id = id
        self.kind = kind
        self.samples = samples
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.peakTimestamp = peakTimestamp
        self.peakEnergy = peakEnergy
        self.features = features
    }
}

public struct MotionGestureSegmenter: Sendable {
    public private(set) var state: GestureSegmenterState
    public private(set) var buffer: MotionRingBuffer

    public var configuration: GestureSegmenterConfiguration
    public var energyAnalyzer: MotionEnergyAnalyzer

    private var previousSample: MotionSample?
    private var gestureStartTimestamp: Double?
    private var lastActiveTimestamp: Double?
    private var peakTimestamp: Double?
    private var peakEnergy: Double
    private var cooldownUntil: Double?

    public init(
        configuration: GestureSegmenterConfiguration = GestureSegmenterConfiguration(),
        energyAnalyzer: MotionEnergyAnalyzer = MotionEnergyAnalyzer()
    ) {
        self.configuration = configuration
        self.energyAnalyzer = energyAnalyzer
        self.state = .idle
        self.buffer = MotionRingBuffer(maxDuration: configuration.ringBufferDuration)
        self.peakEnergy = 0
    }

    public mutating func ingest(_ sample: MotionSample) -> GestureSegment? {
        buffer.append(sample)
        let frame = energyAnalyzer.frame(for: sample, previous: previousSample)
        previousSample = sample

        if let cooldownUntil, sample.timestamp < cooldownUntil {
            state = .cooldown
            return nil
        }

        if state == .cooldown {
            resetGestureState()
            state = .idle
        }

        switch state {
        case .idle:
            if frame.energy >= configuration.startEnergyThreshold {
                beginGesture(at: sample.timestamp, frame: frame)
            }
        case .candidateStarted, .activeGesture:
            updateActiveGesture(frame: frame)
            if frame.energy < configuration.endEnergyThreshold {
                state = .maybeEnding
            } else {
                lastActiveTimestamp = sample.timestamp
            }
        case .maybeEnding:
            updateActiveGesture(frame: frame)
            if frame.energy >= configuration.endEnergyThreshold {
                state = .activeGesture
                lastActiveTimestamp = sample.timestamp
            } else if let lastActiveTimestamp,
                      sample.timestamp - lastActiveTimestamp >= configuration.endConfirmationDuration {
                return finalizeGesture(currentTimestamp: sample.timestamp)
            }
        case .cooldown:
            break
        }

        return nil
    }

    public mutating func reset() {
        state = .idle
        buffer.removeAll()
        previousSample = nil
        resetGestureState()
        cooldownUntil = nil
    }

    private mutating func beginGesture(at timestamp: Double, frame: MotionEnergyFrame) {
        state = .candidateStarted
        gestureStartTimestamp = timestamp
        lastActiveTimestamp = timestamp
        peakTimestamp = timestamp
        peakEnergy = frame.energy
    }

    private mutating func updateActiveGesture(frame: MotionEnergyFrame) {
        if state == .candidateStarted {
            state = .activeGesture
        }

        if frame.energy > peakEnergy {
            peakEnergy = frame.energy
            peakTimestamp = frame.timestamp
        }
    }

    private mutating func finalizeGesture(currentTimestamp: Double) -> GestureSegment? {
        defer {
            cooldownUntil = currentTimestamp + configuration.cooldownDuration
            state = .cooldown
            resetGestureState()
        }

        guard let gestureStartTimestamp,
              let lastActiveTimestamp,
              let peakTimestamp else {
            return nil
        }

        let duration = lastActiveTimestamp - gestureStartTimestamp
        guard duration >= configuration.minimumGestureDuration else {
            return nil
        }

        let start = gestureStartTimestamp - configuration.preRollDuration
        let end = lastActiveTimestamp + configuration.postRollDuration
        let samples = buffer.samples(from: start, through: end)
        guard !samples.isEmpty else { return nil }

        let kind: GestureKind = duration <= configuration.burstMaximumDuration ? .burst : .sequence
        return GestureSegment(
            kind: kind,
            samples: samples,
            startTimestamp: gestureStartTimestamp,
            endTimestamp: lastActiveTimestamp,
            peakTimestamp: peakTimestamp,
            peakEnergy: peakEnergy,
            features: energyAnalyzer.features(for: samples)
        )
    }

    private mutating func resetGestureState() {
        gestureStartTimestamp = nil
        lastActiveTimestamp = nil
        peakTimestamp = nil
        peakEnergy = 0
    }
}

public struct RecognitionLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Double
    public var gestureKindDetected: GestureKind
    public var duration: Double
    public var peakAcceleration: Double
    public var peakRotationRate: Double
    public var bestProfileID: UUID?
    public var bestDistance: Double?
    public var secondBestDistance: Double?
    public var threshold: Double?
    public var margin: Double?
    public var triggered: Bool
    public var audioPlayed: Bool
    public var batteryLevel: Double?
    public var wearContext: WearContext?
    public var burstGateRejectionReason: BurstGateRejectionReason?
    public var tokens: [MotionToken]
    public var classifiedKind: MotionTokenKind?
    public var candidateReports: [CandidateRecognitionReport]
    public var rejectReason: RejectReason?

    public init(
        id: UUID = UUID(),
        timestamp: Double,
        gestureKindDetected: GestureKind,
        duration: Double,
        peakAcceleration: Double,
        peakRotationRate: Double,
        bestProfileID: UUID? = nil,
        bestDistance: Double? = nil,
        secondBestDistance: Double? = nil,
        threshold: Double? = nil,
        margin: Double? = nil,
        triggered: Bool,
        audioPlayed: Bool,
        batteryLevel: Double? = nil,
        wearContext: WearContext? = nil,
        burstGateRejectionReason: BurstGateRejectionReason? = nil,
        tokens: [MotionToken] = [],
        classifiedKind: MotionTokenKind? = nil,
        candidateReports: [CandidateRecognitionReport] = [],
        rejectReason: RejectReason? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.gestureKindDetected = gestureKindDetected
        self.duration = duration
        self.peakAcceleration = peakAcceleration
        self.peakRotationRate = peakRotationRate
        self.bestProfileID = bestProfileID
        self.bestDistance = bestDistance
        self.secondBestDistance = secondBestDistance
        self.threshold = threshold
        self.margin = margin
        self.triggered = triggered
        self.audioPlayed = audioPlayed
        self.batteryLevel = batteryLevel
        self.wearContext = wearContext
        self.burstGateRejectionReason = burstGateRejectionReason
        self.tokens = tokens
        self.classifiedKind = classifiedKind
        self.candidateReports = candidateReports
        self.rejectReason = rejectReason
    }
}
