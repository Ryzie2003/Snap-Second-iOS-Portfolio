import Testing
@testable import Snap_Second

@MainActor
struct OnboardingAnalyticsTests {

    @Test("Survey answers normalize into stable PostHog person properties")
    func surveyAnswersNormalizeForPersonProperties() {
        let answers = SurveyAnswers(
            discoverySource: "TikTok or Instagram",
            startReason: "I want a creative habit I can keep",
            captureTopics: ["Family memories", "Pets"],
            memoryFriction: ["My memories stay buried in Photos"],
            supportNeeds: ["Daily habit", "Spark creativity"],
            cadenceGoal: "A tiny daily habit",
            audienceIntent: "For future me"
        )

        let properties = OnboardingAnalytics.surveyPersonProperties(
            from: answers,
            variant: .control
        )

        #expect(OnboardingAnalytics.surveyVersion(for: .control) == "v1")
        #expect(properties["onboarding_version"] as? String == "v1")
        #expect(properties["onboarding_discovery_source"] as? String == "tiktok_or_instagram")
        #expect(properties["onboarding_start_reason"] as? String == "i_want_a_creative_habit_i_can_keep")
        #expect(properties["onboarding_capture_topics"] as? String == "family_memories|pets")
        #expect(properties["onboarding_capture_topics_count"] as? Int == 2)
        #expect(properties["onboarding_memory_friction"] as? String == "my_memories_stay_buried_in_photos")
        #expect(properties["onboarding_memory_friction_count"] as? Int == 1)
        #expect(properties["onboarding_support_needs"] as? String == "daily_habit|spark_creativity")
        #expect(properties["onboarding_support_needs_count"] as? Int == 2)
        #expect(properties["onboarding_cadence_goal"] as? String == "a_tiny_daily_habit")
        #expect(properties["onboarding_audience_intent"] as? String == "for_future_me")
    }

    @Test("Survey event properties use the explicit session variant")
    func surveyEventPropertiesUseExplicitVariant() {
        let answers = SurveyAnswers(
            discoverySource: "TikTok or Instagram",
            startReason: "I want a creative habit I can keep",
            captureTopics: ["Family memories", "Pets"]
        )

        let properties = OnboardingAnalytics.surveyEventProperties(
            from: answers,
            variant: .previewFirst
        )

        #expect(OnboardingAnalytics.surveyVersion(for: .previewFirst) == "v1")
        #expect(properties["onboarding_variant"] as? String == OnboardingExperimentVariant.previewFirst.rawValue)
        #expect(properties["survey_version"] as? String == "v1")
    }

    @Test("Slugification is lowercase stable and collapses punctuation")
    func slugifyAnswers() {
        #expect(OnboardingAnalytics.slugify("App Store search") == "app_store_search")
        #expect(OnboardingAnalytics.slugify("  Reddit / online community ") == "reddit_online_community")
        #expect(OnboardingAnalytics.slugify("") == "unknown")
    }

    @Test("Experiment resolver accepts current PostHog labels and raw variant values")
    func experimentResolverSupportsConfiguredValues() {
        #expect(OnboardingExperimentVariant.resolve(from: "control") == .control)
        #expect(OnboardingExperimentVariant.resolve(from: "v1") == .previewFirst)
        #expect(OnboardingExperimentVariant.resolve(from: OnboardingExperimentVariant.control.rawValue) == .control)
        #expect(OnboardingExperimentVariant.resolve(from: OnboardingExperimentVariant.previewFirst.rawValue) == .previewFirst)
    }

    @Test("Onboarding step metadata matches the shared intro and converged tail")
    func onboardingStepMetadataMatchesFlow() {
        let q1 = OnboardingStepMetadata.metadata(for: .surveyQ1, variant: .previewFirst)
        let surveyMidpoint = OnboardingStepMetadata.metadata(for: .surveyMidpoint, variant: .previewFirst)
        let q3 = OnboardingStepMetadata.metadata(for: .surveyQ3, variant: .previewFirst)
        let promise = OnboardingStepMetadata.metadata(for: .personalizedPromise, variant: .previewFirst)
        let stat = OnboardingStepMetadata.metadata(for: .socialProof, variant: .previewFirst)
        let quote = OnboardingStepMetadata.metadata(for: .socialProofQuote, variant: .previewFirst)
        let notification = OnboardingStepMetadata.metadata(for: .notificationPermission, variant: .previewFirst)
        let claim = OnboardingStepMetadata.metadata(for: .trialClaim, variant: .previewFirst)
        let montage = OnboardingStepMetadata.metadata(for: .montageWalkthrough, variant: .control)

        #expect(q1.key == "survey_q1")
        #expect(q1.index == 4)
        #expect(surveyMidpoint.key == "survey_midpoint")
        #expect(surveyMidpoint.index == 7)
        #expect(q3.key == "survey_q3")
        #expect(q3.index == 6)
        #expect(promise.group == "personalization")
        #expect(promise.index == 7)
        #expect(stat.key == "social_proof")
        #expect(stat.index == 1)
        #expect(quote.key == "social_proof_quote")
        #expect(quote.index == 2)
        #expect(notification.key == "notification_permission")
        #expect(notification.index == 10)
        #expect(montage.key == "montage_walkthrough")
        #expect(montage.index == 9)
        #expect(claim.key == "trial_claim")
        #expect(claim.index == 13)
    }

    @Test("Onboarding session helpers use the frozen variant")
    func onboardingSessionHelpersUseFrozenVariant() {
        #expect(OnboardingExperimentVariant.control.usesStoryFunnel == false)
        #expect(OnboardingExperimentVariant.previewFirst.usesStoryFunnel == true)
        #expect(OnboardState.surveyStorageKey(for: .control) == "surveyAnswers_v1")
        #expect(OnboardState.surveyStorageKey(for: .previewFirst) == "surveyAnswers_v1")
    }
}
