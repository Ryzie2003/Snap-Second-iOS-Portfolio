import Foundation
import PostHog

private enum OnboardingExperimentConfig {
    static let flagKey = "onboarding_flow_experiment"
    static let cacheKey = "onboarding.experiment.variant"
}

enum OnboardingExperimentVariant: String {
    case control = "v0_control"
    case previewFirst = "v1_preview_first"

    var usesPreviewFirstFlow: Bool {
        self == .previewFirst
    }

    var usesStoryFunnel: Bool {
        self == .previewFirst
    }

    static func resolve(from rawValue: Any?) -> OnboardingExperimentVariant {
        switch rawValue {
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            switch normalized {
            case OnboardingExperimentVariant.control.rawValue, "control", "v0":
                return .control
            case OnboardingExperimentVariant.previewFirst.rawValue,
                 "v1",
                 "preview_first",
                 "preview-first",
                 "previewfirst":
                return .previewFirst
            default:
                return .control
            }
        case let number as NSNumber:
            return number.boolValue ? .previewFirst : .control
        default:
            return .control
        }
    }
}

@MainActor
final class OnboardingExperimentManager: ObservableObject {
    static let shared = OnboardingExperimentManager()
    nonisolated static let cacheKey = OnboardingExperimentConfig.cacheKey

    @Published private(set) var variant: OnboardingExperimentVariant

    private var flagsObserver: NSObjectProtocol?

    private init() {
        variant = Self.cachedVariant

        flagsObserver = NotificationCenter.default.addObserver(
            forName: PostHogSDK.didReceiveFeatureFlags,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncFromPostHog()
            }
        }

        syncFromPostHog()
    }

    func refresh(completion: ((OnboardingExperimentVariant) -> Void)? = nil) {
        Analytics.shared.reloadFeatureFlags { [weak self] in
            Task { @MainActor in
                let resolved = self?.syncFromPostHog() ?? Self.cachedVariant
                completion?(resolved)
            }
        }
    }

    @discardableResult
    func syncFromPostHog() -> OnboardingExperimentVariant {
        let resolved = OnboardingExperimentVariant.resolve(
            from: Analytics.shared.featureFlagValue(key: OnboardingExperimentConfig.flagKey)
        )
        variant = resolved
        UserDefaults.standard.set(resolved.rawValue, forKey: OnboardingExperimentConfig.cacheKey)
        return resolved
    }

    nonisolated static var cachedVariantIfAvailable: OnboardingExperimentVariant? {
        guard let raw = UserDefaults.standard.string(forKey: OnboardingExperimentConfig.cacheKey) else {
            return nil
        }
        return OnboardingExperimentVariant.resolve(from: raw)
    }

    nonisolated static var cachedVariant: OnboardingExperimentVariant {
        cachedVariantIfAvailable ?? .control
    }
}
