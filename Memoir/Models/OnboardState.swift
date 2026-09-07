import SwiftUI
import Combine
import Photos

enum OnboardingStep {
    case welcome
    case surveyIntro
    case surveyQ1
    case surveyQ2
    case surveyQ3
    case surveyMidpoint
    case surveyQ4
    case surveyQ5
    case surveyQ6
    case surveyQ7
    case personalizedPromise
    case socialProofQuote
    case previewTeaser
    case mediaAccessPrimer
    case libraryRecommended
    case previewGenerating
    case montageWalkthrough
    case dailyRhythm
    case socialProof
    case trialGift
    case trialHowItWorks
    case trialClaim

    // Legacy steps kept for compatibility with older screens and analytics mapping.
    case photoPermission
    case notificationPermission
    case projectIntro
    case mediaPicker
    case completion
}

enum AppRoute: Equatable {
    case calendar(UUID)
    case montage(UUID)
}

enum OnboardingPreviewStage: Equatable {
    case idle
    case loading
    case slidesReady
    case videoReady
    case error
}

@MainActor
final class OnboardState: ObservableObject {
    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false

    let sessionVariant: OnboardingExperimentVariant

    @Published var postOnboardingRoute: AppRoute? = nil
    @Published private(set) var step: OnboardingStep
    /// Drives root onboarding slide direction; updated in `transition(to:)` before `step` changes.
    @Published private(set) var onboardingSlideForward: Bool = true
    @Published var surveyAnswers: SurveyAnswers
    @Published var currentProject: Project?
    @Published var lastImportLocalIDs: [String] = []
    @Published var seedShowDates: Bool = false
    @Published var seedTrackID: String? = nil
    @Published var onboardingClipsCount: Int = 0

    @Published var previewBundle: OnboardingPreviewBundle?
    @Published var previewSeedSlide: OnboardingPreviewSlide?
    @Published var previewProgress: Double = 0
    @Published var previewErrorMessage: String?
    @Published private(set) var previewStage: OnboardingPreviewStage = .idle
    @Published private(set) var isGeneratingPreview = false
    @Published private(set) var awaitingSettingsReturn = false
    @Published private(set) var didSkipMediaForNow = false
    @Published private(set) var hasBootstrappedDefaultProject = false
    @Published private(set) var shouldPresentPreviewWhenReady = false

    private let previewService = OnboardingPreviewService()
    private var hasPersistedPreparedClips = false

    private var onboardingStartedAt: Date?
    private var currentStepStartedAt: Date?
    private var currentTrackedStep: OnboardingStep?
    private var pendingStepCompletionProperties: Properties = [:]
    private var onboardingCompletionProperties: Properties = [:]

    init(sessionVariant: OnboardingExperimentVariant) {
        Analytics.shared.configureIfNeeded()

        self.sessionVariant = sessionVariant
        let wasOnboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
        self.step = wasOnboarded ? .completion : .welcome
        self.currentProject = nil
        self.surveyAnswers = Self.loadSurveyAnswers(for: sessionVariant)

        if !wasOnboarded {
            let now = Date()
            onboardingStartedAt = now
            OnboardingAnalytics.trackStarted(variant: sessionVariant)
            startStep(self.step)
        }
    }

    var hasCompletedOnboarding: Bool {
        hasOnboarded
    }

    var usesStoryFunnel: Bool {
        sessionVariant.usesStoryFunnel
    }

    var usesGiftPreviewFlow: Bool {
        sessionVariant.usesStoryFunnel
    }

    func advance() {
        switch step {
        case .welcome:
            transition(to: .socialProof)

        case .socialProof:
            transition(to: .socialProofQuote)

        case .socialProofQuote:
            transition(to: .surveyIntro)

        case .surveyIntro:
            transition(to: .surveyQ1)

        case .surveyQ1:
            transition(to: .surveyQ2)

        case .surveyQ2:
            transition(to: .surveyQ3)

        case .surveyQ3:
            advanceFromSurvey()

        case .personalizedPromise:
            beginPreviewWarmup()

        case .montageWalkthrough:
            transition(to: .notificationPermission)

        case .dailyRhythm:
            transition(to: .trialGift)

        case .previewTeaser:
            showPreview()

        case .previewGenerating:
            transition(to: .notificationPermission)

        case .trialGift:
            transition(to: .trialHowItWorks)

        case .trialHowItWorks:
            transition(to: .trialClaim)

        case .photoPermission:
            if usesGiftPreviewFlow {
                transition(to: .previewTeaser)
            } else {
                transition(to: .projectIntro)
            }

        case .projectIntro:
            transition(to: .mediaPicker)

        case .mediaPicker:
            if onboardingClipsCount > 0 || !lastImportLocalIDs.isEmpty {
                transition(to: .montageWalkthrough)
                OnboardingAnalytics.trackMontagePreviewViewed(
                    clipsCount: onboardingClipsCount,
                    variant: sessionVariant
                )
            } else {
                transition(to: .notificationPermission)
            }

        case .notificationPermission:
            transition(to: .trialGift)

        case .surveyMidpoint, .surveyQ4, .surveyQ5, .surveyQ6, .surveyQ7,
             .mediaAccessPrimer, .libraryRecommended, .trialClaim, .completion:
            break
        }
    }

    func advanceFromSurvey() {
        if usesGiftPreviewFlow {
            transition(to: .personalizedPromise)
        } else {
            transition(to: .projectIntro)
        }
    }

    func markOnboardedFlagOnly() {
        hasOnboarded = true
    }

    func finish(source: String = "notifications") {
        guard step != .completion else { return }

        hasOnboarded = true
        transition(to: .completion)

        let totalDurationMs = onboardingStartedAt.map { milliseconds(since: $0, until: Date()) }
        OnboardingAnalytics.trackOnboardingCompleted(
            totalDurationMs: totalDurationMs,
            source: source,
            variant: sessionVariant,
            additionalProperties: onboardingCompletionProperties
        )
    }

    func recordSurveyAnswers(_ answers: SurveyAnswers) {
        surveyAnswers = answers
    }

    func beginPreviewFlow() {
        requestPreviewAccess(nextStep: .previewGenerating, eagerGenerate: false)
    }

    func beginPreviewWarmup() {
        requestPreviewAccess(nextStep: .previewGenerating, eagerGenerate: true)
    }

    func showPreview() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            didSkipMediaForNow = false
            shouldPresentPreviewWhenReady = true
            if let previewBundle, previewBundle.hasSlidesReady {
                transition(to: .previewGenerating)
                shouldPresentPreviewWhenReady = false
                return
            }
            startPreviewGenerationIfNeeded()
        default:
            beginPreviewFlow()
        }
    }

    private func requestPreviewAccess(nextStep: OnboardingStep, eagerGenerate: Bool) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            handleAuthorizedPreviewAccess(
                status: status,
                nextStep: nextStep,
                eagerGenerate: eagerGenerate
            )

        case .notDetermined:
            Task {
                let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                await MainActor.run {
                    switch newStatus {
                    case .authorized, .limited:
                        self.handleAuthorizedPreviewAccess(
                            status: newStatus,
                            nextStep: nextStep,
                            eagerGenerate: eagerGenerate
                        )
                    case .denied, .restricted:
                        self.recordPhotoPermission(status: newStatus)
                        self.transition(to: .libraryRecommended)
                    case .notDetermined:
                        break
                    @unknown default:
                        self.recordPhotoPermission(status: newStatus)
                        self.transition(to: .libraryRecommended)
                    }
                }
            }

        case .denied, .restricted:
            recordPhotoPermission(status: status)
            transition(to: .libraryRecommended)

        @unknown default:
            recordPhotoPermission(status: status)
            transition(to: .libraryRecommended)
        }
    }

    func openPhotoSettings() {
        awaitingSettingsReturn = true
        pendingStepCompletionProperties["opened_settings_from_onboarding"] = true
        NotificationManager.openSystemSettings()
    }

    func skipMediaForNow() {
        awaitingSettingsReturn = false
        didSkipMediaForNow = true
        shouldPresentPreviewWhenReady = false
        previewSeedSlide = nil
        previewStage = .idle
        pendingStepCompletionProperties["skipped_media_for_now"] = true
        pendingStepCompletionProperties["preview_generated"] = false
        transition(to: .notificationPermission)
    }

    func handleAppDidBecomeActive() {
        guard step == .libraryRecommended, awaitingSettingsReturn else { return }

        awaitingSettingsReturn = false
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        didSkipMediaForNow = false
        recordPhotoPermission(status: status)
        pendingStepCompletionProperties["returned_from_settings_authorized"] = true
        shouldPresentPreviewWhenReady = true
        if let previewBundle, previewBundle.hasSlidesReady {
            transition(to: .previewGenerating)
            shouldPresentPreviewWhenReady = false
            return
        }
        startPreviewGenerationIfNeeded()
    }

    func preparePreviewIfNeeded() {
        guard step == .previewGenerating else { return }

        if let previewBundle {
            syncPreviewState(from: previewBundle)
            return
        }

        guard !isGeneratingPreview else { return }
        startPreviewGenerationIfNeeded()
    }

    func primePreviewWarmupIfAuthorized() {
        guard usesGiftPreviewFlow else { return }
        guard previewBundle == nil, !isGeneratingPreview else { return }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        didSkipMediaForNow = false
        startPreviewGenerationIfNeeded()
    }

    private func startPreviewGenerationIfNeeded() {
        if let previewBundle, !usesGiftPreviewFlow || previewBundle.hasSlidesReady {
            syncPreviewState(from: previewBundle)
            return
        }

        guard !isGeneratingPreview else { return }

        isGeneratingPreview = true
        if previewBundle == nil {
            previewSeedSlide = nil
            previewStage = .loading
            previewProgress = 0.04
        }
        previewErrorMessage = nil

        Task { [weak self] in
            guard let self else { return }
            if usesGiftPreviewFlow {
                do {
                    let slidesBundle = try await self.previewService.makePhotoTimelapseSlidesPreview(
                        progress: { progress in
                            self.previewProgress = progress
                        },
                        seedSlide: { slide in
                            if self.previewBundle == nil {
                                self.previewSeedSlide = slide
                            }
                        }
                    )
                    self.previewBundle = slidesBundle
                    self.previewProgress = 1
                    self.syncPreviewState(from: slidesBundle)
                    if self.shouldPresentPreviewWhenReady {
                        self.transition(to: .previewGenerating)
                        self.shouldPresentPreviewWhenReady = false
                    }
                } catch {
                    self.previewBundle = nil
                    self.previewSeedSlide = nil
                    self.previewErrorMessage = error.localizedDescription
                    self.onboardingClipsCount = 0
                    self.pendingStepCompletionProperties["preview_generated"] = false
                    self.previewStage = .error
                    if self.shouldPresentPreviewWhenReady {
                        self.transition(to: .previewGenerating)
                        self.shouldPresentPreviewWhenReady = false
                    }
                }
            } else {
                do {
                    let bundle = try await self.previewService.makePreview(strategy: .mixedMontage) { progress in
                        self.previewProgress = progress
                    }

                    self.previewBundle = bundle
                    self.previewProgress = 1
                    self.syncPreviewState(from: bundle)
                    self.transition(to: .montageWalkthrough)
                    OnboardingAnalytics.trackMontagePreviewViewed(
                        clipsCount: bundle.preparedClips.count,
                        variant: self.sessionVariant
                    )
                } catch {
                    self.previewBundle = nil
                    self.previewSeedSlide = nil
                    self.previewErrorMessage = error.localizedDescription
                    self.onboardingClipsCount = 0
                    self.pendingStepCompletionProperties["preview_generated"] = false
                    self.previewStage = .error
                    self.transition(to: .montageWalkthrough)
                    OnboardingAnalytics.trackMontagePreviewViewed(
                        clipsCount: 0,
                        variant: self.sessionVariant
                    )
                }
            }

            self.isGeneratingPreview = false
        }
    }

    private func handleAuthorizedPreviewAccess(
        status: PHAuthorizationStatus,
        nextStep: OnboardingStep,
        eagerGenerate: Bool
    ) {
        recordPhotoPermission(status: status)
        didSkipMediaForNow = false

        if eagerGenerate {
            startPreviewGenerationIfNeeded()
        }

        transition(to: nextStep)
    }

    func retryPreviewGeneration() {
        previewBundle = nil
        previewSeedSlide = nil
        previewErrorMessage = nil
        previewProgress = 0
        onboardingClipsCount = 0
        isGeneratingPreview = false
        previewStage = .idle
        shouldPresentPreviewWhenReady = step != .previewGenerating

        if step == .previewGenerating {
            preparePreviewIfNeeded()
        } else {
            startPreviewGenerationIfNeeded()
        }
    }

    func claimTrial(projectStore: ProjectStore, clipStore: ClipStore) {
        Task {
            let (project, didCreateDefaultProject) = await bootstrapDefaultProjectIfNeeded(
                projectStore: projectStore,
                clipStore: clipStore
            )

            onboardingCompletionProperties["default_project_bootstrapped"] = didCreateDefaultProject
            onboardingCompletionProperties["preview_generated"] = previewBundle != nil
            onboardingCompletionProperties["skipped_media_for_now"] = didSkipMediaForNow
            onboardingCompletionProperties["preview_assets_count"] = onboardingClipsCount
            postOnboardingRoute = .calendar(project.id)

            let context = PaywallAnalyticsContext(
                source: "onboarding_trial_claim",
                reason: "claim_free_trial",
                isOnboarding: true,
                onboardingVariant: self.sessionVariant
            )

            finish(source: context.source)

            let didSchedule = ReviewManager.shared.requestOnboardingReview()
            if didSchedule {
                ReviewTrigger.scheduleAfterOnboarding()
            }

            OnboardingAnalytics.trackPaywallShown(context: context)
            PaywallCoordinator.shared.present(context: context)
        }
    }

    // MARK: - Permission results

    func recordPhotoPermission(granted: Bool) {
        pendingStepCompletionProperties = [
            "permission_type": "photos",
            "permission_status": granted ? "accepted" : "denied",
            "photo_permission_status": granted ? "authorized" : "denied"
        ]

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(
                granted ? LegacyEvent.permissionAccepted : LegacyEvent.permissionDenied,
                ["type": "photos"]
            )
        }
    }

    func recordPhotoPermission(status: PHAuthorizationStatus) {
        let normalizedStatus = normalizedPhotoPermissionStatus(status)
        let legacyGranted = status == .authorized || status == .limited

        pendingStepCompletionProperties["permission_type"] = "photos"
        pendingStepCompletionProperties["permission_status"] = legacyGranted ? "accepted" : "denied"
        pendingStepCompletionProperties["photo_permission_status"] = normalizedStatus

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            switch status {
            case .authorized, .limited:
                MP.track(LegacyEvent.permissionAccepted, ["type": "photos"])
            case .denied, .restricted:
                MP.track(LegacyEvent.permissionDenied, ["type": "photos"])
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    func recordNotificationPermission(granted: Bool) {
        pendingStepCompletionProperties = [
            "permission_type": "notifications",
            "permission_status": granted ? "accepted" : "denied"
        ]

        if AnalyticsRollout.dualWriteLegacyOnboarding {
            MP.track(
                granted ? LegacyEvent.permissionAccepted : LegacyEvent.permissionDenied,
                ["type": "notifications"]
            )
        }
    }

    // MARK: - Centralized step tracking

    private func transition(to newStep: OnboardingStep) {
        guard step != newStep else { return }
        let oldIdx = OnboardingStepMetadata.metadata(for: step, variant: sessionVariant).index
        let newIdx = OnboardingStepMetadata.metadata(for: newStep, variant: sessionVariant).index
        onboardingSlideForward = newIdx >= oldIdx
        completeCurrentStepIfNeeded()
        startStep(newStep)
    }

    private func completeCurrentStepIfNeeded() {
        guard let currentTrackedStep, let currentStepStartedAt else { return }

        let durationMs = milliseconds(since: currentStepStartedAt, until: Date())
        OnboardingAnalytics.trackStepCompleted(
            currentTrackedStep,
            variant: sessionVariant,
            durationMs: durationMs,
            additionalProperties: pendingStepCompletionProperties
        )

        pendingStepCompletionProperties = [:]
        self.currentTrackedStep = nil
        self.currentStepStartedAt = nil
    }

    private func startStep(_ newStep: OnboardingStep) {
        step = newStep
        if shouldAutoTrack(newStep) {
            currentTrackedStep = newStep
            currentStepStartedAt = Date()
            OnboardingAnalytics.trackStepViewed(newStep, variant: sessionVariant)
        } else {
            currentTrackedStep = nil
            currentStepStartedAt = nil
        }
    }

    private func syncPreviewState(from bundle: OnboardingPreviewBundle) {
        previewSeedSlide = bundle.slides.first
        onboardingClipsCount = bundle.assetCount
        lastImportLocalIDs = bundle.sourceLocalIDs
        seedShowDates = true
        seedTrackID = bundle.trackID
        previewStage = bundle.hasPlayableVideo ? .videoReady : .slidesReady
        pendingStepCompletionProperties["preview_generated"] = true
        pendingStepCompletionProperties["preview_assets_count"] = bundle.assetCount
    }

    private func bootstrapDefaultProjectIfNeeded(
        projectStore: ProjectStore,
        clipStore: ClipStore
    ) async -> (Project, Bool) {
        if let currentProject {
            hasBootstrappedDefaultProject = true
            UserDefaults.standard.set(currentProject.id.uuidString, forKey: "lastOpenedProjectID")
            return (currentProject, false)
        }

        let (project, didCreateDefaultProject) = projectStore.ensureOnboardingDefaultProject(
            named: "My First Project"
        )

        currentProject = project
        hasBootstrappedDefaultProject = true
        UserDefaults.standard.set(project.id.uuidString, forKey: "lastOpenedProjectID")

        if let previewBundle,
           !hasPersistedPreparedClips,
           !usesGiftPreviewFlow {
            await previewService.persistPreparedClips(
                previewBundle.preparedClips,
                into: project,
                clipStore: clipStore
            )
            hasPersistedPreparedClips = true
        }

        return (project, didCreateDefaultProject)
    }

    private func normalizedPhotoPermissionStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .limited:
            return "limited"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "unknown"
        }
    }

    private func shouldAutoTrack(_ step: OnboardingStep) -> Bool {
        if step == .welcome {
            return false
        }
        return true
    }

    private func milliseconds(since start: Date, until end: Date) -> Int {
        max(Int(end.timeIntervalSince(start) * 1000), 0)
    }

    static func surveyStorageKey(for variant: OnboardingExperimentVariant) -> String {
        _ = variant
        return "surveyAnswers_v1"
    }

    private static func loadSurveyAnswers(for variant: OnboardingExperimentVariant) -> SurveyAnswers {
        let storageKey = surveyStorageKey(for: variant)
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let answers = try? JSONDecoder().decode(SurveyAnswers.self, from: data)
        else {
            return SurveyAnswers()
        }
        return answers
    }
}

extension OnboardState {
    public func navigate(to newStep: OnboardingStep) {
        transition(to: newStep)
    }
}
