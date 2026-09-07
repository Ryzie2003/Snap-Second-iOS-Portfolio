//
//
//  SnapSecondApp.swift
//  Snap Second
//
//  Created by Ryan Zheng on 6/5/25.
//
import SwiftUI
import UserNotifications
import AVFoundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseAppCheck
import RevenueCat
import StoreKit
import FacebookCore

class YourAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
  func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
    if #available(iOS 14.0, *) {
      return AppAttestProvider(app: app)
    } else {
      return DeviceCheckProvider(app: app)
    }
  }
}

final class ReviewTrigger {
    static let key = "shouldAskForReviewNextLaunch"
    static let onboardingKey = "shouldAskForReviewAfterOnboarding"

    static func schedule() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func scheduleAfterOnboarding() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
    }

    static func attemptRequest() {
        guard UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(false, forKey: key)

        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }

    static func attemptRequestAfterOnboardingIfNeeded() {
        guard UserDefaults.standard.bool(forKey: onboardingKey) else { return }
        UserDefaults.standard.set(false, forKey: onboardingKey)
        attemptRequest()
    }
}

private enum DebugLaunchReset {
    static let resetOnboardingArgument = "-resetOnboarding"

    static func applyIfNeeded() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(resetOnboardingArgument) else { return }

        let defaults = UserDefaults.standard
        [
            "hasOnboarded",
            OnboardingExperimentManager.cacheKey,
            "surveyAnswers_v1",
            "surveyAnswers_v2_story",
            ReviewTrigger.key,
            ReviewTrigger.onboardingKey
        ].forEach { defaults.removeObject(forKey: $0) }
#endif
    }
}

private final class MetaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard AppConfiguration.isFacebookConfigured else { return true }
        ApplicationDelegate.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
        return true
    }
}

private enum AppConfiguration {
    private static func string(forKey key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var revenueCatAPIKey: String {
        let configured = string(forKey: "REVENUECAT_API_KEY")
        return configured.isEmpty ? "test_portfolio_configuration_required" : configured
    }

    static var isFacebookConfigured: Bool {
        !string(forKey: "FacebookAppID").isEmpty
    }
}

@MainActor
private final class OnboardingBootstrapState: ObservableObject {
    @Published private(set) var resolvedOnboardingVariant: OnboardingExperimentVariant?

    private var didStart = false

    init() {
        resolvedOnboardingVariant = OnboardingExperimentManager.cachedVariantIfAvailable ?? .control
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        ensureAuthenticatedUserAndRefreshFlags()
    }

    private func ensureAuthenticatedUserAndRefreshFlags() {
        if let user = Auth.auth().currentUser {
            Analytics.shared.syncFirebaseAuth(from: nil, to: user)
            refreshExperimentVariant()
            return
        }

        Auth.auth().signInAnonymously { [weak self] userResult, err in
            Task { @MainActor [weak self] in
                if let err {
                    print("Anon sign-in failed:", err)
                }

                if let user = userResult?.user {
                    Analytics.shared.syncFirebaseAuth(from: nil, to: user)
                }

                self?.refreshExperimentVariant()
            }
        }
    }

    private func refreshExperimentVariant() {
        OnboardingExperimentManager.shared.refresh { [weak self] resolved in
            guard let self else { return }
            if self.resolvedOnboardingVariant == nil {
                self.resolvedOnboardingVariant = resolved
            }
        }
    }
}

@main
struct SnapSecondApp: App {
    @UIApplicationDelegateAdaptor(MetaAppDelegate.self) private var metaAppDelegate

    @StateObject private var bootstrap: OnboardingBootstrapState
    @StateObject private var projectStore: ProjectStore
    @StateObject private var clipStore: ClipStore
    @StateObject private var paywall: PaywallCoordinator
    @StateObject private var authManager: AuthManager
    @StateObject private var purchaseManager: PurchaseManager
    @StateObject private var homeRouter: HomeRouter
    @StateObject private var launchSnapshotStore: CalendarLaunchSnapshotStore

    init() {
        DebugLaunchReset.applyIfNeeded()

        let initialProjectStore = ProjectStore()
        let initialLaunchProject: Project? = {
            guard
                let saved = UserDefaults.standard.string(forKey: "lastOpenedProjectID"),
                let id = UUID(uuidString: saved)
            else {
                return nil
            }
            return initialProjectStore.project(withID: id)
        }()

        _bootstrap = StateObject(wrappedValue: OnboardingBootstrapState())
        _projectStore = StateObject(wrappedValue: initialProjectStore)
        _clipStore = StateObject(wrappedValue: ClipStore.shared)
        _paywall = StateObject(wrappedValue: PaywallCoordinator())
        _authManager = StateObject(wrappedValue: AuthManager.shared)
        _purchaseManager = StateObject(wrappedValue: PurchaseManager.shared)
        _homeRouter = StateObject(wrappedValue: HomeRouter(initialProject: initialLaunchProject))
        _launchSnapshotStore = StateObject(wrappedValue: CalendarLaunchSnapshotStore())

        #if DEBUG
        let providerFactory = AppCheckDebugProviderFactory()
        AppCheck.setAppCheckProviderFactory(providerFactory)
        #else
        AppCheck.setAppCheckProviderFactory(YourAppCheckProviderFactory())
        #endif
        FirebaseApp.configure()

        AppCheck.appCheck().isTokenAutoRefreshEnabled = true

        UNUserNotificationCenter.current().delegate = MemoirNotificationDelegate.shared
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        Purchases.configure(
            with: Configuration.Builder(withAPIKey: AppConfiguration.revenueCatAPIKey)
                .with(appUserID: Auth.auth().currentUser?.uid)
                .build()
        )

        _ = Entitlements.shared

        Analytics.shared.configureIfNeeded()
        Analytics.shared.updateCurrentUserProperties([
            "revenuecat_app_user_id": Purchases.shared.appUserID
        ])
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let variant = bootstrap.resolvedOnboardingVariant {
                    SnapSecondRootView(
                        initialVariant: variant,
                        projectStore: projectStore,
                        clipStore: clipStore,
                        paywall: paywall,
                        authManager: authManager,
                        homeRouter: homeRouter,
                        launchSnapshotStore: launchSnapshotStore
                    )
                } else {
                    OnboardingBootstrapLoadingView()
                }
            }
            .task {
                bootstrap.startIfNeeded()
            }
        }
    }
}

private struct OnboardingBootstrapLoadingView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            ProgressView()
                .controlSize(.large)
        }
    }
}

private struct SnapSecondRootView: View {
    @StateObject private var onboard: OnboardState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPaywall = false
    @State private var didScheduleLaunchMaintenance = false
    @State private var didScheduleRewindNotifications = false

    let projectStore: ProjectStore
    let clipStore: ClipStore
    let paywall: PaywallCoordinator
    let authManager: AuthManager
    let homeRouter: HomeRouter
    let launchSnapshotStore: CalendarLaunchSnapshotStore

    let T = AppTheme.sunsetGlow.theme

    init(
        initialVariant: OnboardingExperimentVariant,
        projectStore: ProjectStore,
        clipStore: ClipStore,
        paywall: PaywallCoordinator,
        authManager: AuthManager,
        homeRouter: HomeRouter,
        launchSnapshotStore: CalendarLaunchSnapshotStore
    ) {
        _onboard = StateObject(wrappedValue: OnboardState(sessionVariant: initialVariant))
        self.projectStore = projectStore
        self.clipStore = clipStore
        self.paywall = paywall
        self.authManager = authManager
        self.homeRouter = homeRouter
        self.launchSnapshotStore = launchSnapshotStore
    }

    private func onboardingTopPadding(
        for step: OnboardingStep,
        screenHeight: CGFloat,
        safeAreaTop: CGFloat
    ) -> CGFloat {
        guard !step.ownsRootTopPadding else { return 0 }

        let basePadding: CGFloat
        switch LayoutScale.forScreenHeight(screenHeight) {
        case .small:
            basePadding = 8
        case .medium:
            basePadding = 12
        case .large:
            basePadding = 16
        }

        return safeAreaTop < 24 ? basePadding + 4 : basePadding
    }

    private func onboardingScreenIdentity(for step: OnboardingStep) -> String {
        "\(onboard.sessionVariant.rawValue):\(OnboardingStepMetadata.metadata(for: step, variant: onboard.sessionVariant).key)"
    }

    @ViewBuilder
    private func onboardingScreen(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingStoryIntroScreen(
                primary: T.core.primary,
                accent: T.core.accent
            )
            .environmentObject(onboard)

        case .surveyIntro:
            SurveyIntroScreen(
                onContinue: { onboard.advance() },
                onSkip: { onboard.advance() }
            )
            .environmentObject(onboard)

        case .surveyQ1, .surveyQ2, .surveyQ3, .surveyMidpoint, .surveyQ4, .surveyQ5, .surveyQ6, .surveyQ7:
            SurveyFlow(displayStep: step)
                .environmentObject(onboard)

        case .projectIntro:
            ProjectIntroView()
                .environmentObject(onboard)

        case .mediaPicker:
            Group {
                if let proj = onboard.currentProject {
                    NavigationStack {
                        OnboardingLibraryPickerView(project: proj)
                    }
                    .environmentObject(onboard)
                } else {
                    Color.clear.ignoresSafeArea()
                }
            }

        case .personalizedPromise:
            OnboardingPersonalizedPromiseScreen()
                .environmentObject(onboard)

        case .mediaAccessPrimer:
            OnboardingMediaAccessPrimerScreen()
                .environmentObject(onboard)

        case .libraryRecommended:
            OnboardingLibraryRecommendedScreen()
                .environmentObject(onboard)

        case .previewGenerating:
            OnboardingPreviewGeneratingScreen()
                .environmentObject(onboard)

        case .montageWalkthrough:
            Group {
                if let proj = onboard.currentProject {
                    OnboardingMontagePreviewScreen(project: proj)
                        .environmentObject(onboard)
                } else {
                    OnboardingPreviewPlaybackScreen()
                        .environmentObject(onboard)
                }
            }

        case .dailyRhythm:
            OnboardingDailyRhythmScreen()
                .environmentObject(onboard)

        case .socialProof:
            OnboardingSocialProofScreen()
                .environmentObject(onboard)

        case .socialProofQuote:
            OnboardingSocialProofQuoteScreen()
                .environmentObject(onboard)

        case .previewTeaser:
            OnboardingPreviewTeaserScreen()
                .environmentObject(onboard)

        case .trialGift:
            OnboardingTrialGiftScreen()
                .environmentObject(onboard)

        case .trialHowItWorks:
            OnboardingTrialHowItWorksScreen()
                .environmentObject(onboard)

        case .trialClaim:
            OnboardingTrialClaimScreen()
                .environmentObject(onboard)

        case .notificationPermission:
            RemindersScreen()
                .environmentObject(onboard)

        default:
            LaunchRouter()
                .environmentObject(onboard)
                .environmentObject(projectStore)
                .environmentObject(clipStore)
                .environmentObject(homeRouter)
                .environmentObject(launchSnapshotStore)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            OnboardingSlideHost(
                step: onboard.step,
                slideForward: onboard.onboardingSlideForward,
                identity: onboardingScreenIdentity(for:),
                screen: { step in AnyView(onboardingScreen(for: step)) }
            )
            .safeAreaPadding(
                .top,
                onboardingTopPadding(
                    for: onboard.step,
                    screenHeight: proxy.size.height,
                    safeAreaTop: proxy.safeAreaInsets.top
                )
            )
            .task(priority: .utility) {
                await AVWarmup.primeAudioSession()
            }
            .task(priority: .userInitiated) {
                clipStore.loadOnceIfNeeded()
            }
            .environmentObject(onboard)
            .environmentObject(clipStore)
            .environmentObject(projectStore)
            .environmentObject(Entitlements.shared)
            .environmentObject(paywall)
            .environmentObject(launchSnapshotStore)
            .onReceive(paywall.$isPresented) { showPaywall = $0 }
            .onChange(of: showPaywall) { _, isPresented in
                if !isPresented {
                    ReviewTrigger.attemptRequestAfterOnboardingIfNeeded()
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallSheet()
            }
            .environmentObject(authManager)
            .onAppear {
                registerBackupEnumerator(projectStore: projectStore, clipStore: clipStore)

                CloudBackupService.shared.registerRestoreHandlers(
                    probe: { [weak clipStore] id, ext in
                        let store = clipStore ?? ClipStore.shared
                        return store.urlForClipIdString(id, ext: ext)
                    },
                    commit: { [weak clipStore] id, tempURL, createdAt, journalId, ext in
                        let store = clipStore ?? ClipStore.shared
                        try store.importRestoredFile(
                            idString: id,
                            tempURL: tempURL,
                            createdAt: createdAt,
                            journalId: journalId,
                            ext: ext
                        )
                    }
                )

                CloudBackupService.shared.registerJournalHandlers(
                    snapshot: { [weak projectStore] in
                        guard let projectStore else { return [] }
                        return projectStore.projects.enumerated().map { index, project in
                            CloudBackupService.BackupJournal(
                                id: project.id.uuidString,
                                name: project.name,
                                createdAt: project.created,
                                type: project.type.rawValue,
                                sortIndex: index
                            )
                        }
                    },
                    rebuild: { [weak projectStore] journals in
                        guard let projectStore else { return }
                        await MainActor.run {
                            let newProjects = journals.compactMap { journal -> Project? in
                                guard let uuid = UUID(uuidString: journal.id) else { return nil }
                                return Project(
                                    id: uuid,
                                    name: journal.name,
                                    created: journal.createdAt,
                                    type: ProjectType(rawValue: journal.type) ?? .dailyJournal
                                )
                            }
                            projectStore.replaceAll(with: newProjects)
                        }
                    }
                )

                scheduleLaunchMaintenanceIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                MP.track(Event.appOpen)
                scheduleRewindNotificationsIfNeeded()
                ReviewTrigger.attemptRequest()
                onboard.handleAppDidBecomeActive()

                ReviewManager.shared.recordAppOpen()
                ReviewManager.shared.evaluateOnLaunch()
            } else if phase == .background {
                launchSnapshotStore.refreshLastOpenedProjectIfPossible(
                    projectStore: projectStore,
                    clipStore: clipStore
                )
            }
        }
    }

    private func scheduleLaunchMaintenanceIfNeeded() {
        guard !didScheduleLaunchMaintenance else { return }
        didScheduleLaunchMaintenance = true

        Task(priority: .background) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                _ = projectStore.recoverMissingProjectsFromClips()
            }
        }
    }

    private func scheduleRewindNotificationsIfNeeded() {
        guard !didScheduleRewindNotifications else { return }
        didScheduleRewindNotifications = true

        Task(priority: .background) {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await RewindNotificationCoordinator.shared.evaluateAndScheduleIfNeeded()
        }
    }
}

private extension OnboardingStep {
    var ownsRootTopPadding: Bool {
        switch self {
        case .surveyIntro,
             .surveyQ1,
             .surveyQ2,
             .surveyQ3,
             .surveyMidpoint,
             .surveyQ4,
             .surveyQ5,
             .surveyQ6,
             .surveyQ7,
             .personalizedPromise,
             .mediaAccessPrimer,
             .libraryRecommended,
             .previewGenerating,
             .dailyRhythm,
             .previewTeaser,
             .trialGift,
             .trialHowItWorks,
             .trialClaim,
             .mediaPicker:
            return true
        default:
            return false
        }
    }
}

private struct OnboardingSlideHost: View {
    let step: OnboardingStep
    let slideForward: Bool
    let identity: (OnboardingStep) -> String
    let screen: (OnboardingStep) -> AnyView

    @State private var activeStep: OnboardingStep
    @State private var outgoingStep: OnboardingStep?
    @State private var incomingOffset: CGFloat = 0
    @State private var outgoingOffset: CGFloat = 0
    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width
    @State private var transitionToken = UUID()

    init(
        step: OnboardingStep,
        slideForward: Bool,
        identity: @escaping (OnboardingStep) -> String,
        screen: @escaping (OnboardingStep) -> AnyView
    ) {
        self.step = step
        self.slideForward = slideForward
        self.identity = identity
        self.screen = screen
        _activeStep = State(initialValue: step)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let outgoingStep {
                    screen(outgoingStep)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: outgoingOffset)
                        .zIndex(0)
                }

                screen(activeStep)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(x: incomingOffset)
                    .zIndex(1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear {
                containerWidth = max(proxy.size.width, 1)
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                containerWidth = max(newWidth, 1)
            }
        }
        .ignoresSafeArea()
        .onChange(of: step) { oldStep, newStep in
            guard identity(oldStep) != identity(newStep) else {
                activeStep = newStep
                return
            }

            let width = max(containerWidth, 1)
            let direction = slideForward ? 1.0 : -1.0
            let token = UUID()

            transitionToken = token
            outgoingStep = oldStep
            activeStep = newStep
            incomingOffset = width * direction
            outgoingOffset = 0

            withAnimation(.easeInOut(duration: 0.32)) {
                incomingOffset = 0
                outgoingOffset = -width * direction
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard transitionToken == token else { return }
                outgoingStep = nil
                outgoingOffset = 0
            }
        }
    }
}

private struct LaunchRouter: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var clipStore: ClipStore

    var body: some View {
        MainTabView()
            .task { await preloadLaunchCalendarIfNeeded() }
    }

    @MainActor
    private func preloadLaunchCalendarIfNeeded() async {
        if let saved = UserDefaults.standard.string(forKey: "lastOpenedProjectID"),
           let savedID = UUID(uuidString: saved),
           let project = projectStore.projects.first(where: { $0.id == savedID }) {

            switch project.type {
            case .dailyJournal, .timelapse:
                clipStore.loadOnceIfNeeded()
                await clipStore.ensureLoaded()
                await clipStore.predecodeInitialCalendarThumbs(for: project)
            case .collections:
                break
            }
        }
    }
}
