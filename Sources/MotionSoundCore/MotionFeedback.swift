import Foundation

public struct GestureFeedbackEngine: Sendable {
    public var matcher: MotionTemplateMatcher
    public var evaluator: GestureQualityEvaluator
    public var templateBuilder: MotionTemplateBuilder

    public init(
        matcher: MotionTemplateMatcher = MotionTemplateMatcher(),
        evaluator: GestureQualityEvaluator = GestureQualityEvaluator(),
        templateBuilder: MotionTemplateBuilder = MotionTemplateBuilder()
    ) {
        self.matcher = matcher
        self.evaluator = evaluator
        self.templateBuilder = templateBuilder
    }

    public func applyFalseTrigger(
        event: GestureRecognitionEvent,
        to profiles: [GestureProfile],
        createdAt: Date = Date()
    ) -> [GestureProfile] {
        guard event.triggered, let triggeredProfile = event.profile else {
            return profiles
        }

        let negativeTemplate = templateBuilder.makeTemplate(
            label: "\(triggeredProfile.name)-false-trigger",
            kind: event.segment.kind,
            samples: event.segment.samples,
            createdAt: createdAt
        )

        return profiles.map { profile in
            guard profile.id == triggeredProfile.id else { return profile }
            return updatedProfile(profile, addingNegativeTemplate: negativeTemplate, updatedAt: createdAt)
        }
    }

    public func updatedProfile(
        _ profile: GestureProfile,
        addingNegativeTemplate negativeTemplate: MotionTemplate,
        updatedAt: Date = Date()
    ) -> GestureProfile {
        var updated = profile
        updated.negativeTemplates.append(negativeTemplate)

        let calibration = matcher.calibrateThreshold(
            positiveTemplates: updated.templates,
            negativeWindows: updated.negativeTemplates.map(\.samples)
        )
        let calibrationReport = matcher.calibrationReport(
            positiveTemplates: updated.templates,
            negativeWindows: updated.negativeTemplates.map(\.samples)
        )
        let report = evaluator.evaluate(
            templates: updated.templates,
            negativeTemplates: updated.negativeTemplates
        )

        updated.acceptanceThreshold = calibration.threshold
        updated.marginThreshold = max(updated.marginThreshold, calibration.recommendedMarginThreshold)
        updated.strictness = min(1, max(updated.strictness + 0.08, calibrationReport.recommendedStrictness))
        if var thresholds = updated.thresholds {
            thresholds.triggerScore = max(thresholds.triggerScore, calibrationReport.triggerScore)
            thresholds.marginScore = max(thresholds.marginScore, calibrationReport.marginScore)
            thresholds.strictness = max(thresholds.strictness, updated.strictness)
            updated.thresholds = thresholds
        }
        updated.quality = report.quality
        updated.updatedAt = updatedAt
        return updated
    }
}
