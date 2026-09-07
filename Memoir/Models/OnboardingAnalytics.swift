import Foundation

struct PaywallAnalyticsContext: Equatable {
    let source: String
    let reason: String?
    let isOnboarding: Bool
    let onboardingVariant: OnboardingExperimentVariant?

    init(
        source: String,
        reason: String?,
        isOnboarding: Bool,
        onboardingVariant: OnboardingExperimentVariant? = nil
    ) {
        self.source = source
        self.reason = reason
        self.isOnboarding = isOnboarding
        self.onboardingVariant = onboardingVariant
    }

    static let generic = PaywallAnalyticsContext(
        source: "generic_paywall",
        reason: nil,
        isOnboarding: false,
        onboardingVariant: nil
    )

    var baseProperties: Properties {
        var properties: Properties = ["source": source]
        if let reason, !reason.isEmpty {
            properties["paywall_reason"] = reason
        }
        if let onboardingVariant {
            properties["onboarding_variant"] = onboardingVariant.rawValue
        }
        return properties
    }
}

struct OnboardingStepMetadata: Equatable {
    let key: String
    let index: Int
    let group: String
    let screenName: String
    let permissionType: String?

    static func metadata(
        for step: OnboardingStep,
        variant: OnboardingExperimentVariant
    ) -> OnboardingStepMetadata {
        switch step {
        case .welcome:
            return .init(key: "welcome", index: 0, group: "intro", screenName: "Onboarding Welcome", permissionType: nil)
        case .surveyIntro:
            return .init(key: "survey_intro", index: 3, group: "survey", screenName: "Onboarding Survey Intro", permissionType: nil)
        case .surveyQ1:
            return .init(key: "survey_q1", index: 4, group: "survey", screenName: "Onboarding Survey Q1", permissionType: nil)
        case .surveyQ2:
            return .init(key: "survey_q2", index: 5, group: "survey", screenName: "Onboarding Survey Q2", permissionType: nil)
        case .surveyQ3:
            return .init(key: "survey_q3", index: 6, group: "survey", screenName: "Onboarding Survey Q3", permissionType: nil)
        case .surveyMidpoint:
            return .init(key: "survey_midpoint", index: 7, group: "survey", screenName: "Onboarding Survey Midpoint", permissionType: nil)
        case .surveyQ4:
            return .init(key: "survey_q4", index: 8, group: "survey", screenName: "Onboarding Survey Q4", permissionType: nil)
        case .surveyQ5:
            return .init(key: "survey_q5", index: 9, group: "survey", screenName: "Onboarding Survey Q5", permissionType: nil)
        case .surveyQ6:
            return .init(key: "survey_q6", index: 10, group: "survey", screenName: "Onboarding Survey Q6", permissionType: nil)
        case .surveyQ7:
            return .init(key: "survey_q7", index: 11, group: "survey", screenName: "Onboarding Survey Q7", permissionType: nil)
        case .personalizedPromise:
            return .init(key: "personalized_promise", index: 7, group: "personalization", screenName: "Onboarding Personalized Promise", permissionType: nil)
        case .socialProofQuote:
            return .init(key: "social_proof_quote", index: 2, group: "trust", screenName: "Onboarding Social Proof Reviews", permissionType: nil)
        case .previewTeaser:
            return .init(key: "preview_teaser", index: 8, group: "media_preview", screenName: "Onboarding Preview Teaser", permissionType: nil)
        case .mediaAccessPrimer:
            return .init(key: "media_access_primer", index: 8, group: "media_preview", screenName: "Onboarding Media Access Primer", permissionType: nil)
        case .libraryRecommended:
            return .init(key: "library_recommended", index: 8, group: "media_preview", screenName: "Onboarding Library Recommended", permissionType: "photos")
        case .previewGenerating:
            return .init(key: "preview_generating", index: 9, group: "preview", screenName: "Onboarding Preview Generating", permissionType: nil)
        case .dailyRhythm:
            return .init(key: "daily_rhythm", index: 10, group: "habit", screenName: "Onboarding Daily Rhythm", permissionType: nil)
        case .socialProof:
            return .init(key: "social_proof", index: 1, group: "trust", screenName: "Onboarding Social Proof Rating", permissionType: nil)
        case .trialGift:
            return .init(key: "trial_gift", index: 11, group: "trial", screenName: "Onboarding Trial Gift", permissionType: nil)
        case .trialHowItWorks:
            return .init(key: "trial_how_it_works", index: 12, group: "trial", screenName: "Onboarding Trial How It Works", permissionType: nil)
        case .trialClaim:
            return .init(key: "trial_claim", index: 13, group: "trial", screenName: "Onboarding Trial Claim", permissionType: nil)
        case .photoPermission:
            return .init(key: "photo_permission", index: 8, group: "permissions", screenName: "Onboarding Photos Permission", permissionType: "photos")
        case .projectIntro:
            return .init(key: "project_intro", index: 7, group: "project_setup", screenName: "Onboarding Project Intro", permissionType: nil)
        case .mediaPicker:
            return .init(key: "media_picker", index: 8, group: "media_import", screenName: "Onboarding Media Picker", permissionType: nil)
        case .montageWalkthrough:
            return .init(key: "montage_walkthrough", index: 9, group: "preview", screenName: "Onboarding Montage Walkthrough", permissionType: nil)
        case .notificationPermission:
            return .init(key: "notification_permission", index: 10, group: "permissions", screenName: "Onboarding Notification Permission", permissionType: "notifications")
        case .completion:
            return .init(key: "completion", index: 14, group: "completion", screenName: "Onboarding Completion", permissionType: nil)
        }
    }
}

enum OnboardingAnalytics {
    static func surveyVersion(for variant: OnboardingExperimentVariant) -> String {
        _ = variant
        return "v1"
    }

    static func trackStarted(variant: OnboardingExperimentVariant) {
        Analytics.shared.track(
            event: Event.onboardingStarted,
            properties: ["onboarding_variant": variant.rawValue]
        )

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyEvent.onboardingStart)
        }
    }

    static func trackStepViewed(_ step: OnboardingStep, variant: OnboardingExperimentVariant) {
        let metadata = OnboardingStepMetadata.metadata(for: step, variant: variant)
        var properties = stepProperties(for: metadata, variant: variant)
        if let permissionType = metadata.permissionType {
            properties["permission_type"] = permissionType
        }

        Analytics.shared.track(event: Event.onboardingStepViewed, properties: properties)
        Analytics.shared.screen(name: metadata.screenName, properties: properties)

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyOnboardingEvents.entered(metadata.key), ["step": metadata.key])
            if let permissionType = metadata.permissionType {
                MP.track(LegacyEvent.permissionPromptShown, ["type": permissionType])
            }
        }
    }

    static func trackStepCompleted(
        _ step: OnboardingStep,
        variant: OnboardingExperimentVariant,
        durationMs: Int,
        additionalProperties: Properties = [:]
    ) {
        let metadata = OnboardingStepMetadata.metadata(for: step, variant: variant)
        var properties = stepProperties(for: metadata, variant: variant)
        properties["duration_ms"] = durationMs
        properties.merge(additionalProperties) { _, new in new }

        Analytics.shared.track(event: Event.onboardingStepCompleted, properties: properties)

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyOnboardingEvents.completed(metadata.key), ["step": metadata.key])
        }
    }

    static func trackWelcomeGetStartedTapped(variant: OnboardingExperimentVariant) {
        let metadata = OnboardingStepMetadata.metadata(for: .welcome, variant: variant)
        Analytics.shared.track(
            event: Event.onboardingStepCompleted,
            properties: [
                "step_key": metadata.key,
                "step_index": metadata.index,
                "step_group": metadata.group,
                "onboarding_variant": variant.rawValue,
                "action": "get_started_tap"
            ]
        )

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyEvent.welcomeGetStartedTap)
        }
    }

    static func trackStoryIntroBeatViewed(
        index: Int,
        title: String,
        variant: OnboardingExperimentVariant
    ) {
        let key = "story_intro_\(index)"
        let properties: Properties = [
            "onboarding_variant": variant.rawValue,
            "step_key": key,
            "step_index": index - 1,
            "step_group": "intro",
            "beat_title": slugify(title)
        ]

        Analytics.shared.track(event: Event.onboardingStepViewed, properties: properties)
        Analytics.shared.screen(name: "Onboarding Story Intro \(index)", properties: properties)
    }

    static func trackStoryIntroBeatAdvanced(
        index: Int,
        action: String,
        variant: OnboardingExperimentVariant
    ) {
        let properties: Properties = [
            "onboarding_variant": variant.rawValue,
            "step_key": "story_intro_\(index)",
            "step_index": index - 1,
            "step_group": "intro",
            "action": action
        ]
        Analytics.shared.track(event: Event.onboardingStepCompleted, properties: properties)
    }

    static func trackMontagePreviewViewed(
        clipsCount: Int,
        variant: OnboardingExperimentVariant
    ) {
        let previewStep: OnboardingStep = variant.usesStoryFunnel
            ? .previewGenerating
            : .montageWalkthrough
        let metadata = OnboardingStepMetadata.metadata(for: previewStep, variant: variant)
        Analytics.shared.track(
            event: Event.onboardingStepViewed,
            properties: [
                "step_key": metadata.key,
                "step_index": metadata.index,
                "step_group": metadata.group,
                "onboarding_variant": variant.rawValue,
                "clips_in_onboarding": clipsCount
            ]
        )

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyEvent.montagePreviewViewed, ["clips_in_onboarding": clipsCount])
        }
    }

    static func trackMontagePreviewContinueTapped(variant: OnboardingExperimentVariant) {
        let previewStep: OnboardingStep = variant.usesStoryFunnel
            ? .previewGenerating
            : .montageWalkthrough
        let metadata = OnboardingStepMetadata.metadata(for: previewStep, variant: variant)
        Analytics.shared.track(
            event: Event.onboardingStepCompleted,
            properties: [
                "step_key": metadata.key,
                "step_index": metadata.index,
                "step_group": metadata.group,
                "onboarding_variant": variant.rawValue,
                "action": "continue_tap"
            ]
        )

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyEvent.montagePreviewContinueTap)
        }
    }

    static func trackSurveySubmitted(_ answers: SurveyAnswers, variant: OnboardingExperimentVariant) {
        let eventProperties = surveyEventProperties(from: answers, variant: variant)
        let personProperties = surveyPersonProperties(from: answers, variant: variant)

        Analytics.shared.track(
            event: Event.onboardingSurveySubmitted,
            properties: eventProperties,
            userProperties: personProperties
        )
    }

    static func trackOnboardingCompleted(
        totalDurationMs: Int?,
        source: String,
        variant: OnboardingExperimentVariant,
        additionalProperties: Properties = [:]
    ) {
        var eventProperties: Properties = [
            "source": source,
            "onboarding_variant": variant.rawValue
        ]
        if let totalDurationMs {
            eventProperties["duration_ms"] = totalDurationMs
        }
        eventProperties.merge(additionalProperties) { _, new in new }

        let timestamp = iso8601Timestamp(for: Date())
        let personProperties: UserProperties = [
            "onboarding_version": surveyVersion(for: variant),
            "onboarding_completed": true,
            "onboarding_completed_at": timestamp
        ]

        Analytics.shared.track(
            event: Event.onboardingCompleted,
            properties: eventProperties,
            userProperties: personProperties
        )

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyEvent.onboardingComplete)
        }
    }

    static func trackPaywallShown(context: PaywallAnalyticsContext) {
        Analytics.shared.track(
            event: Event.onboardingPaywallShown,
            properties: context.baseProperties
        )

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyEvent.paywallShown, context.baseProperties)
        }
    }

    static func trackPaywallCTATapped(context: PaywallAnalyticsContext, packageID: String) {
        var properties = context.baseProperties
        properties["package_id"] = packageID

        Analytics.shared.track(event: Event.onboardingPaywallCtaTapped, properties: properties)

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(LegacyEvent.paywallCtaTap, [
                "reason": context.reason ?? context.source,
                "package": packageID
            ])
        }
    }

    static func trackSubscriptionPurchaseStarted(context: PaywallAnalyticsContext, packageID: String) {
        var properties = context.baseProperties
        properties["package_id"] = packageID

        Analytics.shared.track(event: Event.subscriptionPurchaseStarted, properties: properties)
    }

    static func trackSubscriptionPurchaseCompleted(
        context: PaywallAnalyticsContext,
        packageID: String,
        entitlementIsActive: Bool
    ) {
        var properties = context.baseProperties
        properties["package_id"] = packageID
        properties["entitlement_is_active"] = entitlementIsActive

        Analytics.shared.track(event: Event.subscriptionPurchaseCompleted, properties: properties)
    }

    static func trackSubscriptionEntitlementActivated(source: String, entitlementSource: String?) {
        var properties: Properties = ["source": source]
        if let entitlementSource, !entitlementSource.isEmpty {
            properties["entitlement_source"] = entitlementSource
        }

        Analytics.shared.track(event: Event.subscriptionEntitlementActivated, properties: properties)
    }

    static func legacySurveyAnswersPayload(from answers: SurveyAnswers) -> [String: Any] {
        [
            "key": answers.discoverySource ?? "",
            "startReason": answers.startReason ?? "",
            "captureTopics": answers.captureTopics,
            "memoryFriction": answers.memoryFriction,
            "supportNeeds": answers.supportNeeds,
            "cadenceGoal": answers.cadenceGoal ?? "",
            "audienceIntent": answers.audienceIntent ?? ""
        ]
    }

    static func surveyPersonProperties(
        from answers: SurveyAnswers,
        variant: OnboardingExperimentVariant
    ) -> UserProperties {
        let normalizedDiscoverySource = slugify(answers.discoverySource ?? "")
        let normalizedStartReason = slugify(answers.startReason ?? "")
        let captureTopics = joinedSlugs(answers.captureTopics)
        let memoryFriction = joinedSlugs(answers.memoryFriction)
        let supportNeeds = joinedSlugs(answers.supportNeeds)
        let cadenceGoal = slugify(answers.cadenceGoal ?? "")
        let audienceIntent = slugify(answers.audienceIntent ?? "")

        return [
            "onboarding_version": surveyVersion(for: variant),
            "onboarding_discovery_source": normalizedDiscoverySource,
            "onboarding_start_reason": normalizedStartReason,
            "onboarding_capture_topics": captureTopics,
            "onboarding_capture_topics_count": answers.captureTopics.count,
            "onboarding_memory_friction": memoryFriction,
            "onboarding_memory_friction_count": answers.memoryFriction.count,
            "onboarding_support_needs": supportNeeds,
            "onboarding_support_needs_count": answers.supportNeeds.count,
            "onboarding_cadence_goal": cadenceGoal,
            "onboarding_audience_intent": audienceIntent
        ]
    }

    static func surveyEventProperties(
        from answers: SurveyAnswers,
        variant: OnboardingExperimentVariant
    ) -> Properties {
        [
            "onboarding_variant": variant.rawValue,
            "survey_version": surveyVersion(for: variant),
            "survey_discovery_source": slugify(answers.discoverySource ?? ""),
            "survey_start_reason": slugify(answers.startReason ?? ""),
            "survey_capture_topics": joinedSlugs(answers.captureTopics),
            "survey_capture_topics_count": answers.captureTopics.count,
            "survey_memory_friction": joinedSlugs(answers.memoryFriction),
            "survey_memory_friction_count": answers.memoryFriction.count,
            "survey_support_needs": joinedSlugs(answers.supportNeeds),
            "survey_support_needs_count": answers.supportNeeds.count,
            "survey_cadence_goal": slugify(answers.cadenceGoal ?? ""),
            "survey_audience_intent": slugify(answers.audienceIntent ?? "")
        ]
    }

    static func slugify(_ value: String) -> String {
        let lowercase = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercase.isEmpty else { return "unknown" }

        let replaced = lowercase.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }

        let collapsed = String(replaced)
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        return collapsed.isEmpty ? "unknown" : collapsed
    }

    static func joinedSlugs(_ values: [String]) -> String {
        let slugs = values.map(slugify).filter { !$0.isEmpty }
        return slugs.isEmpty ? "none" : slugs.joined(separator: "|")
    }

    private static func stepProperties(
        for metadata: OnboardingStepMetadata,
        variant: OnboardingExperimentVariant
    ) -> Properties {
        [
            "onboarding_variant": variant.rawValue,
            "step_key": metadata.key,
            "step_index": metadata.index,
            "step_group": metadata.group
        ]
    }

    private static func iso8601Timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
