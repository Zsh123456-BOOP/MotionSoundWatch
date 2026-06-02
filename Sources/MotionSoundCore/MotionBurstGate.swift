import Foundation

public enum BurstGateRejectionReason: String, Codable, Equatable, Sendable {
    case durationTooLong
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
    public var maximumDuration: Double
    public var requiresDominantAxisMatch: Bool
    public var axisMismatchMinimumPeakAcceleration: Double

    public init(
        minimumPeakAcceleration: Double = 0.55,
        minimumPeakRotationRate: Double = 0,
        maximumDuration: Double = 0.9,
        requiresDominantAxisMatch: Bool = true,
        axisMismatchMinimumPeakAcceleration: Double = 1.2
    ) {
        self.minimumPeakAcceleration = minimumPeakAcceleration
        self.minimumPeakRotationRate = minimumPeakRotationRate
        self.maximumDuration = maximumDuration
        self.requiresDominantAxisMatch = requiresDominantAxisMatch
        self.axisMismatchMinimumPeakAcceleration = axisMismatchMinimumPeakAcceleration
    }
}

public struct MotionBurstGate: Equatable, Sendable {
    public var configuration: BurstGateConfiguration

    public init(configuration: BurstGateConfiguration = BurstGateConfiguration()) {
        self.configuration = configuration
    }

    public func decision(for segment: GestureSegment, profile: GestureProfile) -> BurstGateDecision {
        guard segment.kind == .burst, profile.kind == .burst else {
            return .allowed
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
           segment.features.peakAcceleration < configuration.axisMismatchMinimumPeakAcceleration {
            return .rejected(.dominantAxisMismatch)
        }

        return .allowed
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
}
