import Foundation
import FirebaseAuth
import Mixpanel
import PostHog

typealias Properties = [String: Any]
typealias UserProperties = [String: Any]

enum AnalyticsRollout {
    static let dualWriteLegacyOnboarding = true
    static let dualWriteLegacySurveyStorage = true
}

enum Event {
    static let appOpen = "app_open"
    static let reviewPromptTriggered = "Review Prompt Triggered"

    static let onboardingStarted = "onboarding_started"
    static let onboardingStepViewed = "onboarding_step_viewed"
    static let onboardingStepCompleted = "onboarding_step_completed"
    static let onboardingCompleted = "onboarding_completed"
    static let onboardingSurveySubmitted = "onboarding_survey_submitted"
    static let onboardingPaywallShown = "onboarding_paywall_shown"
    static let onboardingPaywallCtaTapped = "onboarding_paywall_cta_tapped"
    static let subscriptionPurchaseStarted = "subscription_purchase_started"
    static let subscriptionPurchaseCompleted = "subscription_purchase_completed"
    static let subscriptionEntitlementActivated = "subscription_entitlement_activated"
}

enum LegacyEvent {
    static let onboardingStart = "onboarding_start"
    static let onboardingComplete = "onboarding_complete"
    static let montagePreviewViewed = "onboarding_montage_preview_viewed"
    static let paywallShown = "paywall_shown"
    static let paywallCtaTap = "paywall_cta_tap"
    static let permissionPromptShown = "onboarding_permission_prompt_shown"
    static let permissionAccepted = "onboarding_permission_accepted"
    static let permissionDenied = "onboarding_permission_denied"
    static let welcomeGetStartedTap = "onboarding_welcome_get_started_tap"
    static let montagePreviewContinueTap = "onboarding_montage_preview_continue_tap"
}

enum LegacyOnboardingEvents {
    static func entered(_ stepKey: String) -> String { "onboarding_\(stepKey)_entered" }
    static func completed(_ stepKey: String) -> String { "onboarding_\(stepKey)_completed" }
}

private enum AnalyticsConfiguration {
    static let mixpanelTokenKey = "MIXPANEL_TOKEN"
    static let postHogAPIKeyKey = "POSTHOG_API_KEY"
    static let postHogHostKey = "POSTHOG_HOST"

    static var mixpanelToken: String {
        string(forKey: mixpanelTokenKey)
    }

    static var postHogAPIKey: String {
        string(forKey: postHogAPIKeyKey)
    }

    static var postHogHost: String {
        let configured = string(forKey: postHogHostKey)
        return configured.isEmpty ? "https://us.i.posthog.com" : configured
    }

    static var isPostHogConfigured: Bool {
        !postHogAPIKey.isEmpty
    }

    static var isMixpanelConfigured: Bool {
        !mixpanelToken.isEmpty
    }

    private static func string(forKey key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class PostHogAnalyticsProvider {
    private var isConfigured = false

    func configureIfNeeded() {
        guard !isConfigured, AnalyticsConfiguration.isPostHogConfigured else { return }

        let config = PostHogConfig(
            apiKey: AnalyticsConfiguration.postHogAPIKey,
            host: AnalyticsConfiguration.postHogHost
        )
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = false
        config.personProfiles = .identifiedOnly

        PostHogSDK.shared.setup(config)
        isConfigured = true
    }

    func capture(
        event: String,
        properties: Properties = [:],
        userProperties: UserProperties? = nil,
        userPropertiesSetOnce: UserProperties? = nil
    ) {
        guard isConfigured else { return }

        if let userProperties, let userPropertiesSetOnce {
            PostHogSDK.shared.capture(
                event,
                properties: properties,
                userProperties: userProperties,
                userPropertiesSetOnce: userPropertiesSetOnce
            )
        } else if let userProperties {
            PostHogSDK.shared.capture(
                event,
                properties: properties,
                userProperties: userProperties
            )
        } else {
            PostHogSDK.shared.capture(event, properties: properties)
        }
    }

    func screen(name: String, properties: Properties = [:]) {
        guard isConfigured else { return }
        PostHogSDK.shared.screen(name, properties: properties)
    }

    func identify(
        distinctId: String,
        userProperties: UserProperties = [:],
        userPropertiesSetOnce: UserProperties = [:]
    ) {
        guard isConfigured else { return }
        PostHogSDK.shared.identify(
            distinctId,
            userProperties: userProperties,
            userPropertiesSetOnce: userPropertiesSetOnce
        )
    }

    func alias(alias: String) {
        guard isConfigured else { return }
        PostHogSDK.shared.alias(alias)
    }

    func register(properties: Properties) {
        guard isConfigured, !properties.isEmpty else { return }
        PostHogSDK.shared.register(properties)
    }

    func reloadFeatureFlags(completion: (() -> Void)? = nil) {
        guard isConfigured else {
            completion?()
            return
        }

        if let completion {
            PostHogSDK.shared.reloadFeatureFlags {
                completion()
            }
        } else {
            PostHogSDK.shared.reloadFeatureFlags()
        }
    }

    func featureFlagValue(key: String) -> Any? {
        guard isConfigured else { return nil }
        return PostHogSDK.shared.getFeatureFlag(key)
    }

    func reset() {
        guard isConfigured else { return }
        PostHogSDK.shared.reset()
    }
}

private extension Properties {
    var mixpanelProperties: [String: MixpanelType] {
        self.reduce(into: [String: MixpanelType]()) { partialResult, entry in
            if let value = LegacyAnalytics.mixpanelValue(for: entry.value) {
                partialResult[entry.key] = value
            }
        }
    }
}

final class LegacyAnalytics {
    static let shared = LegacyAnalytics()

    private var isConfigured = false

    private init() {}

    func configureIfNeeded() {
        guard !isConfigured, AnalyticsConfiguration.isMixpanelConfigured else { return }
        Mixpanel.initialize(token: AnalyticsConfiguration.mixpanelToken, trackAutomaticEvents: false)
        isConfigured = true
    }

    func track(_ event: String, properties: Properties = [:]) {
        guard isConfigured else { return }
        Mixpanel.mainInstance().track(event: event, properties: properties.mixpanelProperties)
    }

    func identify(_ distinctId: String, userProperties: UserProperties = [:]) {
        guard isConfigured else { return }
        Mixpanel.mainInstance().identify(distinctId: distinctId)
        let peopleProperties = userProperties.mixpanelProperties
        if !peopleProperties.isEmpty {
            Mixpanel.mainInstance().people.set(properties: peopleProperties)
        }
    }

    func alias(previousId: String, newId: String) {
        guard isConfigured, previousId != newId else { return }
        Mixpanel.mainInstance().createAlias(newId, distinctId: previousId)
    }

    func registerSuperProperties(_ properties: Properties) {
        guard isConfigured else { return }
        Mixpanel.mainInstance().registerSuperProperties(properties.mixpanelProperties)
    }

    func reset() {
        guard isConfigured else { return }
        Mixpanel.mainInstance().reset()
    }

    static func mixpanelValue(for value: Any) -> MixpanelType? {
        if let mixpanelType = value as? MixpanelType {
            return mixpanelType
        }

        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let number as NSNumber:
            return number
        case let date as Date:
            return date
        default:
            return nil
        }
    }
}

enum MP {
    static func track(_ name: String, _ props: Properties = [:]) {
        LegacyAnalytics.shared.track(name, properties: props)
    }
}

final class Analytics {
    static let shared = Analytics()

    private let postHog = PostHogAnalyticsProvider()
    private(set) var currentDistinctId: String?
    private var globalProperties: Properties = [:]
    private var didConfigure = false

    private init() {}

    func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        LegacyAnalytics.shared.configureIfNeeded()
        postHog.configureIfNeeded()

        let info = Bundle.main.infoDictionary
        let sharedProperties: Properties = [
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown",
            "platform": "iOS",
            "is_testflight": Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        ]

        self.globalProperties = sharedProperties
        LegacyAnalytics.shared.registerSuperProperties(sharedProperties)
        postHog.register(properties: sharedProperties)
    }

    func track(
        event: String,
        properties: Properties = [:],
        userProperties: UserProperties? = nil,
        userPropertiesSetOnce: UserProperties? = nil
    ) {
        postHog.capture(
            event: event,
            properties: properties,
            userProperties: userProperties,
            userPropertiesSetOnce: userPropertiesSetOnce
        )
    }

    func screen(name: String, properties: Properties = [:]) {
        postHog.screen(name: name, properties: properties)
    }

    func identify(
        distinctId: String,
        userProperties: UserProperties = [:],
        userPropertiesSetOnce: UserProperties = [:]
    ) {
        currentDistinctId = distinctId
        if AnalyticsRollout.dualWriteLegacyOnboarding {
            LegacyAnalytics.shared.identify(distinctId, userProperties: userProperties)
        }
        postHog.identify(
            distinctId: distinctId,
            userProperties: userProperties,
            userPropertiesSetOnce: userPropertiesSetOnce
        )
    }

    func alias(previousId: String, newId: String, userProperties: UserProperties = [:]) {
        guard previousId != newId else {
            identify(distinctId: newId, userProperties: userProperties)
            return
        }

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            LegacyAnalytics.shared.alias(previousId: previousId, newId: newId)
        }
        if currentDistinctId == previousId {
            postHog.alias(alias: newId)
        }
        identify(distinctId: newId, userProperties: userProperties)
    }

    func updateCurrentUserProperties(
        _ userProperties: UserProperties = [:],
        setOnce userPropertiesSetOnce: UserProperties = [:]
    ) {
        guard let distinctId = currentDistinctId ?? Auth.auth().currentUser?.uid else { return }
        identify(
            distinctId: distinctId,
            userProperties: userProperties,
            userPropertiesSetOnce: userPropertiesSetOnce
        )
    }

    func syncFirebaseAuth(from previousUser: User?, to newUser: User?) {
        guard didConfigure else { return }

        guard let newUser else {
            reset()
            return
        }

        let setOnce: UserProperties = [
            "first_seen_platform": "iOS"
        ]
        let userProperties = firebaseUserProperties(for: newUser)

        if let previousUser, previousUser.uid != newUser.uid {
            if previousUser.isAnonymous && !newUser.isAnonymous {
                alias(previousId: previousUser.uid, newId: newUser.uid, userProperties: userProperties)
            } else {
                identify(
                    distinctId: newUser.uid,
                    userProperties: userProperties,
                    userPropertiesSetOnce: setOnce
                )
            }
        } else {
            identify(
                distinctId: newUser.uid,
                userProperties: userProperties,
                userPropertiesSetOnce: setOnce
            )
        }
    }

    func reset() {
        currentDistinctId = nil
        if AnalyticsRollout.dualWriteLegacyOnboarding {
            LegacyAnalytics.shared.reset()
            LegacyAnalytics.shared.registerSuperProperties(globalProperties)
        }
        postHog.reset()
        postHog.register(properties: globalProperties)
    }

    func reloadFeatureFlags(completion: (() -> Void)? = nil) {
        postHog.reloadFeatureFlags(completion: completion)
    }

    func featureFlagValue(key: String) -> Any? {
        postHog.featureFlagValue(key: key)
    }

    private func firebaseUserProperties(for user: User) -> UserProperties {
        var properties: UserProperties = [
            "firebase_uid": user.uid,
            "is_anonymous": user.isAnonymous,
            "identity_provider": user.isAnonymous ? "firebase_anonymous" : "firebase_authenticated"
        ]

        if let email = user.email, !email.isEmpty {
            properties["email"] = email
        }

        return properties
    }
}
