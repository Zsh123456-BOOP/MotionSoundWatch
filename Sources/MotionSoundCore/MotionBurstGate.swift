import Foundation

public enum BurstGateRejectionReason: String, Codable, Equatable, Sendable {
    case kindMismatch
    case durationTooLong
    case durationTooShort
    case peakAccelerationTooLow
    case peakRotationTooLow
    case dominantAxisMismatch
}

public struct BurstGateDecision: Equatable, Sendable {
    public var isAllowed: Bool
    public var reason: BurstGateRejectionReason?

    public init(isAllowed: Bool, reason: BurstGateRejectionReason? = nil) {
        self.isAllowed = isAllowed
        self.reason = reason
    }

    public static var allowed: BurstGateDecision {
        BurstGateDecision(isAllowed: true)
    }

    public static func rejected(_ reason: BurstGateRejectionReason) -> BurstGateDecision {
        BurstGateDecision(isAllowed: false, reason: reason)
    }
}

public struct BurstGateConfiguration: Equatable, Sendable {
    public var minimumPeakAcceleration: Double
    public var minimumPeakRotationRate: Double
    public var minimumDuration: Double
    public var maximumDuration: Double
    public var requiresDominantAxisMatch: Bool
    public var axisMismatchMinimumPeakAcceleration: Double
    public var comboMinimumDurationRatio: Double
    public var comboMaximumDurationRatio: Double
    public var comboMinimumPeakAccelerationRatio: Double
    public var comboMinimumPeakRotationRatio: Double

    public init(
        minimumPeakAcceleration: Double = 0.35,
        minimumPeakRotationRate: Double = 0,
        minimumDuration: Double = 0.18,
        maximumDuration: Double = 0.9,
        requiresDominantAxisMatch: Bool = true,
        axisMismatchMinimumPeakAcceleration: Double = 1.6,
        comboMinimumDurationRatio: Double = 0.35,
        comboMaximumDurationRatio: Double = 1.8,
        comboMinimumPeakAccelerationRatio: Double = 0.18,
        comboMinimumPeakRotationRatio: Double = 0.10
    ) {
        self.minimumPeakAcceleration = minimumPeakAcceleration
        self.minimumPeakRotationRate = minimumPeakRotationRate
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.requiresDominantAxisMatch = requiresDominantAxisMatch
        self.axisMismatchMinimumPeakAcceleration = axisMismatchMinimumPeakAcceleration
        self.comboMinimumDurationRatio = comboMinimumDurationRatio
        self.comboMaximumDurationRatio = comboMaximumDurationRatio
        self.comboMinimumPeakAccelerationRatio = comboMinimumPeakAccelerationRatio
        self.comboMinimumPeakRotationRatio = comboMinimumPeakRotationRatio
    }
}

public struct MotionBurstGate: Equatable, Sendable {
    public var configuration: BurstGateConfiguration

    public init(configuration: BurstGateConfiguration = BurstGateConfiguration()) {
        self.configuration = configuration
    }

    public func decision(for segment: GestureSegment, profile: GestureProfile) -> BurstGateDecision {
        if profile.kind == .combo {
            return comboDecision(for: segment, profile: profile)
        }

        guard segment.kind == .burst, profile.kind == .burst else {
            return .allowed
        }

        guard segment.duration >= configuration.minimumDuration else {
            return .rejected(.durationTooShort)
        }

        guard segment.duration <= configuration.maximumDuration else {
            return .rejected(.durationTooLong)
        }

        guard segment.features.peakAcceleration >= configuration.minimumPeakAcceleration else {
            return .rejected(.peakAccelerationTooLow)
        }

        guard segment.features.peakRotationRate >= configuration.minimumPeakRotationRate else {
            return .rejected(.peakRotationTooLow)
        }

        if configuration.requiresDominantAxisMatch,
           let profileAxis = dominantAxis(for: profile),
           profileAxis != segment.features.dominantAxis,
           !variantAxisMatches(profile: profile, segmentAxis: segment.features.dominantAxis),
           segment.features.peakAcceleration < configuration.axisMismatchMinimumPeakAcceleration {
            return .rejected(.dominantAxisMismatch)
        }

        return .allowed
    }

    private func comboDecision(for segment: GestureSegment, profile: GestureProfile) -> BurstGateDecision {
        if let expectedKind = inferredKind(for: profile), expectedKind != segment.kind {
            return .rejected(.kindMismatch)
        }

        guard segment.duration >= comboMinimumDuration(for: profile) else {
            return .rejected(.durationTooShort)
        }

        if segment.kind == .burst, segment.duration > configuration.maximumDuration {
            return .rejected(.durationTooLong)
        }
        if segment.kind == .sequence,
           let maximumDuration = comboMaximumDuration(for: profile),
           segment.duration > maximumDuration {
            return .rejected(.durationTooLong)
        }

        let profilePeakAcceleration = profile.templates
            .compactMap(\.features?.peakAcceleration)
            .max() ?? 0
        let profilePeakRotation = profile.templates
            .compactMap(\.features?.peakRotationRate)
            .max() ?? 0

        let minimumPeakAcceleration = max(
            configuration.minimumPeakAcceleration,
            profilePeakAcceleration * configuration.comboMinimumPeakAccelerationRatio
        )
        guard segment.features.peakAcceleration >= minimumPeakAcceleration else {
            return .rejected(.peakAccelerationTooLow)
        }

        let minimumPeakRotation = max(
            configuration.minimumPeakRotationRate,
            profilePeakRotation * configuration.comboMinimumPeakRotationRatio
        )
        guard segment.features.peakRotationRate >= minimumPeakRotation else {
            return .rejected(.peakRotationTooLow)
        }

        if configuration.requiresDominantAxisMatch,
           let profileAxis = dominantAxis(for: profile),
           profileAxis != segment.features.dominantAxis,
           !variantAxisMatches(profile: profile, segmentAxis: segment.features.dominantAxis),
           segment.features.peakAcceleration < configuration.axisMismatchMinimumPeakAcceleration {
            return .rejected(.dominantAxisMismatch)
        }

        return .allowed
    }

    private func inferredKind(for profile: GestureProfile) -> GestureKind? {
        guard let averageDuration = averageTemplateDuration(for: profile) else { return nil }
        return averageDuration <= configuration.maximumDuration ? .burst : .sequence
    }

    private func comboMinimumDuration(for profile: GestureProfile) -> Double {
        guard let averageDuration = averageTemplateDuration(for: profile) else {
            return configuration.minimumDuration
        }
        return max(configuration.minimumDuration, averageDuration * configuration.comboMinimumDurationRatio)
    }

    private func comboMaximumDuration(for profile: GestureProfile) -> Double? {
        guard let averageDuration = averageTemplateDuration(for: profile) else { return nil }
        return max(configuration.maximumDuration, averageDuration * configuration.comboMaximumDurationRatio)
    }

    private func averageTemplateDuration(for profile: GestureProfile) -> Double? {
        let durations = profile.templates.map(\.rawDuration).filter { $0 > 0 }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }

    private func dominantAxis(for profile: GestureProfile) -> Int? {
        let axes = profile.templates.compactMap(\.features?.dominantAxis)
        guard !axes.isEmpty else { return nil }

        var counts: [Int: Int] = [:]
        for axis in axes {
            counts[axis, default: 0] += 1
        }

        return counts.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
    }

    private func variantAxisMatches(profile: GestureProfile, segmentAxis: Int) -> Bool {
        guard let variants = profile.signatureVariants, !variants.isEmpty else {
            return false
        }
        for variant in variants {
            let templateIDs = Set(variant.templateIDs)
            let axes = profile.templates
                .filter { templateIDs.contains($0.id) }
                .compactMap(\.features?.dominantAxis)
            if axes.contains(segmentAxis) {
                return true
            }
        }
        return false
    }
}
