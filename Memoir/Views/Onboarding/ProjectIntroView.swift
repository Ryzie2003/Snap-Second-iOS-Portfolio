import SwiftUI

struct ProjectIntroView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    @EnvironmentObject var onboard: OnboardState
    @EnvironmentObject var projectStore: ProjectStore
    @EnvironmentObject var entitlements: Entitlements

    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        OnboardingFullscreenResponsiveScreen {
            VStack(spacing: isCondensedLayout ? 22 : 28) {
                ZStack {
                    Circle()
                        .fill(T.primaryMuted.opacity(0.9))
                        .frame(width: isCondensedLayout ? 110 : 126, height: isCondensedLayout ? 110 : 126)

                    Circle()
                        .stroke(T.border.opacity(0.85), lineWidth: 1)
                        .frame(width: isCondensedLayout ? 110 : 126, height: isCondensedLayout ? 110 : 126)

                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: isCondensedLayout ? 40 : 46, weight: .semibold))
                        .foregroundStyle(T.core.accent)
                }
                .shadow(
                    color: scheme == .dark ? .black.opacity(0.24) : .black.opacity(0.08),
                    radius: 16,
                    y: 8
                )

                VStack(spacing: 12) {
                    Text("Create your first project")
                        .font(OnboardingTypography.fixed(isCondensedLayout ? 28 : 32, weight: .bold))
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)

                    Text("Pick a few photos or videos next, and we’ll use them to start your story.")
                        .font(OnboardingTypography.preferred(.body, weight: .regular))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            Button(action: continueToProject) {
                Text("Continue")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func continueToProject() {
        if onboard.currentProject == nil {
            do {
                let project = try projectStore.createProject(
                    name: "My Snap Second",
                    entitlements: entitlements
                )
                onboard.currentProject = project
                UserDefaults.standard.set(project.id.uuidString, forKey: "lastOpenedProjectID")
            } catch {
                print("Failed to create default project:", error)
            }
        }

        if let project = onboard.currentProject {
            UserDefaults.standard.set(project.id.uuidString, forKey: "lastOpenedProjectID")
        }
        onboard.advance()
    }
}

struct OnboardingPersonalizedPromiseScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var usesStoryFunnel: Bool { onboard.usesStoryFunnel }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        if usesStoryFunnel {
            storyFunnelGiftLayout
        } else {
            legacyPersonalizedPromiseLayout
        }
    }

    /// Full-screen gift interstitial that mirrors the reference composition using Snap Second branding.
    private var storyFunnelGiftLayout: some View {
        OnboardingFullscreenResponsiveScreen {
            VStack(spacing: 0) {
                StoryFunnelLogoBadge(imageName: "SplashLogo")
                    .padding(.bottom, isCondensedLayout ? 20 : 30)

                VStack(spacing: 6) {
                    Text("Before you start\ncreating your life story")
                        .font(OnboardingTypography.fixed(isCondensedLayout ? 18 : 22, weight: .semibold))
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("with Snap Second")
                        .font(OnboardingTypography.fixed(isCondensedLayout ? 16 : 20, weight: .medium))
                        .foregroundStyle(T.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, isCondensedLayout ? 12 : 28)

                Text("A gift from us")
                    .font(OnboardingTypography.preferred(isCondensedLayout ? .callout : .body, weight: .medium))
                    .foregroundStyle(T.textSecondary)
                    .padding(.top, isCondensedLayout ? 24 : 48)
            }
        } footer: {
            Button {
                onboard.advance()
            } label: {
                Text("Let's Go")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCondensedLayout ? 14 : 16)
            }
            .buttonStyle(.plain)
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .onAppear {
            onboard.primePreviewWarmupIfAuthorized()
        }
    }

    private var legacyPersonalizedPromiseLayout: some View {
        OnboardingStepScreen(
            step: .personalizedPromise,
            title: "This can feel a lot more personal",
            subtitle: "We’ll tailor Snap Second to how you use it."
        ) {
            VStack(spacing: 22) {
                VStack(spacing: 18) {
                    StoryFunnelBadge(icon: "sparkles", accent: T.core.accent)

                    Text("Tiny moments.\nA bigger picture.")
                        .font(
                            .system(
                                size: OnboardingTypography.scaled(36),
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)

                    Text("Snap Second is about helping the small, easy-to-miss parts of life actually stay with you.")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 30)
                .background(
                    LinearGradient(
                        colors: [T.primaryMuted, T.core.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(T.border, lineWidth: 1)
                )
            }
        } footer: {
            OnboardingPrimaryButton(title: "Keep going") {
                onboard.advance()
            }
        }
    }
}

struct OnboardingMediaAccessPrimerScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        OnboardingStepScreen(
            step: .mediaAccessPrimer,
            title: "Ready for your first reveal?",
            subtitle: "Allow Photos once and Snap Second will assemble the opening cut for you."
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 18) {
                    StoryFunnelBadge(icon: "photo.on.rectangle.angled", accent: T.core.accent)

                    Text("Your recent photos and videos become a 30-second first pass.")
                        .font(
                            .system(
                                size: OnboardingTypography.scaled(isCondensedLayout ? 26 : 30),
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)

                    Text("No naming step. No setup detour. Just the fastest path to feeling the value.")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .background(T.primaryMuted, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(T.border, lineWidth: 1)
                )

                OnboardingMiniFeatureRow(
                    icon: "lock.shield.fill",
                    title: "You stay in control",
                    body: "You can change access later in Settings."
                )

                Link(destination: URL(string: "https://snapsecond.co/privacy")!) {
                    Text("Questions on privacy? View Privacy Policy.")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.core.primary)
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "Create my 30-second preview") {
                onboard.beginPreviewFlow()
            }
        }
    }
}

struct OnboardingLibraryRecommendedScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        OnboardingStepScreen(
            step: .libraryRecommended,
            title: "Library access recommended",
            subtitle: "That’s what unlocks your personal first cut."
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 16) {
                    StoryFunnelBadge(icon: "gearshape.fill", accent: T.core.accent)

                    Text("For the best Snap Second experience, Photos access is recommended.")
                        .font(
                            .system(
                                size: OnboardingTypography.scaled(isCondensedLayout ? 26 : 30),
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)

                    Text("Turn it on in Settings and we’ll jump straight back into building your preview.")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .background(T.primaryMuted, in: RoundedRectangle(cornerRadius: 30, style: .continuous))

                OnboardingMiniFeatureRow(
                    icon: "bolt.fill",
                    title: "No extra setup",
                    body: "As soon as access is on, the preview starts."
                )

                OnboardingMiniFeatureRow(
                    icon: "arrow.right.circle.fill",
                    title: "Skip if you want",
                    body: "You can keep going now and add clips later."
                )

                Link(destination: URL(string: "https://snapsecond.co/privacy")!) {
                    Text("Questions on privacy? View Privacy Policy.")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.core.primary)
                }
            }
        } footer: {
            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Open Settings") {
                    onboard.openPhotoSettings()
                }

                OnboardingSecondaryButton(title: "Skip for now") {
                    onboard.skipMediaForNow()
                }
            }
        }
    }
}

struct OnboardingPreviewGeneratingScreen: View {
    var body: some View {
        OnboardingPreviewRevealScreen()
    }
}

struct OnboardingDailyRhythmScreen: View {
    @EnvironmentObject private var onboard: OnboardState

    var body: some View {
        OnboardingStepScreen(
            step: .dailyRhythm,
            title: "A rhythm that stays easy",
            subtitle: "Capture. Revisit. Repeat."
        ) {
            VStack(spacing: 12) {
                OnboardingNumberedStepCard(
                    number: "01",
                    title: "Save a moment",
                    body: "One quick clip or photo is enough."
                )

                OnboardingNumberedStepCard(
                    number: "02",
                    title: "Let it turn into a story",
                    body: "Snap Second gives you a starting point fast."
                )

                OnboardingNumberedStepCard(
                    number: "03",
                    title: "Come back tomorrow",
                    body: "The habit gets better as days stack up."
                )
            }
        } footer: {
            OnboardingPrimaryButton(title: "Continue") {
                onboard.advance()
            }
        }
    }
}

struct OnboardingSocialProofScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        OnboardingFullscreenResponsiveScreen {
            VStack(spacing: isCondensedLayout ? 22 : 28) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "laurel.leading")
                            .font(.system(size: isCondensedLayout ? 42 : 52, weight: .regular))
                            .foregroundStyle(T.core.accent.opacity(0.9))

                        VStack(spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("4.8")
                                    .font(
                                        .system(
                                            size: OnboardingTypography.scaled(isCondensedLayout ? 56 : 68),
                                            weight: .bold,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(T.core.text)
                                Text("/5")
                                    .font(
                                        .system(
                                            size: OnboardingTypography.scaled(isCondensedLayout ? 24 : 30),
                                            weight: .semibold,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(T.textSecondary)
                            }

                            Text("Highly rated")
                                .font(
                                    .system(
                                        size: OnboardingTypography.scaled(isCondensedLayout ? 18 : 22),
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(T.core.text)
                        }

                        Image(systemName: "laurel.trailing")
                            .font(.system(size: isCondensedLayout ? 42 : 52, weight: .regular))
                            .foregroundStyle(T.core.accent.opacity(0.9))
                    }
                    .padding(.horizontal, 8)

                    Rectangle()
                        .fill(T.border.opacity(0.55))
                        .frame(height: 1)
                        .padding(.horizontal, isCondensedLayout ? 24 : 40)

                    Text("Ratings from the App Store")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: isCondensedLayout ? 8 : 10) {
                        ForEach(0..<5, id: \.self) { i in
                            Image(systemName: "star.fill")
                                .font(.system(size: isCondensedLayout ? 22 : 26, weight: .semibold))
                                .foregroundStyle(T.core.accent)
                                .offset(y: socialProofStarArcOffset(index: i))
                        }
                    }
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
        } footer: {
            Button(action: { onboard.advance() }) {
                Text("Continue")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCondensedLayout ? 14 : 16)
            }
            .buttonStyle(.plain)
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func socialProofStarArcOffset(index: Int) -> CGFloat {
        let d = abs(CGFloat(index) - 2)
        return -4 + d * 3
    }
}

private struct OnboardingStoreReview: Identifiable {
    let id: String
    let quote: String
}

struct OnboardingSocialProofQuoteScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    private let reviews: [OnboardingStoreReview] = [
        .init(
            id: "r1",
            quote: "This app is everything I want in a second a day app. I’ve been able to create a backlog of yearly second a day videos that make the Live Photo feature so valuable. "
        ),
        .init(
            id: "r2",
            quote: "I’ve been searching for exactly this. Love having longer length videos and especially as many clips as I want. It makes me pause and talk in the moments of my life because I know I’ll have somewhere magical to put them."
        ),
        .init(
            id: "r3",
            quote: "Love Snap Second - it’s allowed me to track my working life every day and see how I’ve transformed as a person. Really great idea and execution; the UI is seamless and the music is amazing."
        )
    ]

    var body: some View {
        OnboardingFullscreenResponsiveScreen {
            VStack(spacing: isCondensedLayout ? 18 : 24) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "laurel.leading")
                            .font(.system(size: isCondensedLayout ? 36 : 44, weight: .regular))
                            .foregroundStyle(T.core.accent.opacity(0.9))

                        Text("Loved by users")
                            .font(
                                .system(
                                    size: OnboardingTypography.scaled(isCondensedLayout ? 18 : 20),
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(T.core.text)
                            .multilineTextAlignment(.center)

                        Image(systemName: "laurel.trailing")
                            .font(.system(size: isCondensedLayout ? 36 : 44, weight: .regular))
                            .foregroundStyle(T.core.accent.opacity(0.9))
                    }

                    Rectangle()
                        .fill(T.border.opacity(0.55))
                        .frame(height: 1)
                        .padding(.horizontal, isCondensedLayout ? 20 : 32)

                    TabView {
                        ForEach(reviews) { item in
                            VStack(alignment: .leading, spacing: 16) {
                                Text("“\(item.quote)”")
                                    .font(
                                        .system(
                                            size: OnboardingTypography.scaled(isCondensedLayout ? 16 : 18),
                                            weight: .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(T.core.text)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack {
                                    Spacer(minLength: 0)
                                    HStack(spacing: 6) {
                                        ForEach(0..<5, id: \.self) { i in
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(T.core.accent)
                                                .offset(y: socialProofQuoteStarArcOffset(index: i))
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .frame(maxWidth: isCondensedLayout ? 260 : 300, alignment: .leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .padding(.horizontal, 20)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .automatic))
                    .frame(height: isCondensedLayout ? 300 : 360)
            }
        } footer: {
            Button(action: { onboard.advance() }) {
                Text("Continue")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCondensedLayout ? 14 : 16)
            }
            .buttonStyle(.plain)
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func socialProofQuoteStarArcOffset(index: Int) -> CGFloat {
        let d = abs(CGFloat(index) - 2)
        return -2 + d * 2
    }
}

struct OnboardingPreviewTeaserScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var usesStoryFunnel: Bool { onboard.usesStoryFunnel }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        if usesStoryFunnel {
            storyFunnelBirdsEyeLayout
        } else {
            legacyPreviewTeaserLayout
        }
    }

    /// Full-screen teaser that uses the same palette and CTA treatment as the rest of onboarding.
    private var storyFunnelBirdsEyeLayout: some View {
        OnboardingFullscreenResponsiveScreen {
            VStack(spacing: 0) {
                StoryFunnelBadge(icon: "film.stack.fill", accent: T.core.accent)
                    .padding(.bottom, isCondensedLayout ? 20 : 28)

                Text("See your moments at a glance.")
                    .font(
                        .system(
                            size: OnboardingTypography.scaled(isCondensedLayout ? 22 : 24),
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(T.core.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, isCondensedLayout ? 20 : 28)

                Text("We'll make a short preview from your last 5 years of moments.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(T.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, isCondensedLayout ? 20 : 32)
                    .padding(.top, 12)
            }
        } footer: {
            Button {
                onboard.advance()
            } label: {
                Text(
                    onboard.shouldPresentPreviewWhenReady && onboard.isGeneratingPreview
                        ? "Preparing preview..."
                        : "Show preview"
                )
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCondensedLayout ? 14 : 16)
            }
            .buttonStyle(.plain)
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(onboard.shouldPresentPreviewWhenReady && onboard.isGeneratingPreview)
        }
    }

    private var legacyPreviewTeaserLayout: some View {
        OnboardingStepScreen(
            step: .previewTeaser,
            title: "Let’s zoom out on your life",
            subtitle: "We’ll turn your recent camera roll into a 30-second first look."
        ) {
            VStack(spacing: 20) {
                VStack(spacing: 18) {
                    StoryFunnelBadge(icon: "paperplane.fill", accent: T.core.accent)

                    Text("A bird’s-eye view of the moments you already captured.")
                        .font(
                            .system(
                                size: OnboardingTypography.scaled(30),
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)

                    Text("No manual project setup first. We’ll build the opening cut for you.")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .background(
                    LinearGradient(
                        colors: [T.primaryMuted, T.core.surface],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 30, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(T.border, lineWidth: 1)
                )

                OnboardingMiniFeatureRow(
                    icon: "film.stack.fill",
                    title: "One quick reveal",
                    body: "Your camera roll, condensed into something easier to feel."
                )
            }
        } footer: {
            OnboardingPrimaryButton(
                title: onboard.shouldPresentPreviewWhenReady && onboard.isGeneratingPreview
                    ? "Preparing preview..."
                    : "Show me"
            ) {
                onboard.advance()
            }
            .disabled(onboard.shouldPresentPreviewWhenReady && onboard.isGeneratingPreview)
        }
    }
}

struct OnboardingTrialGiftScreen: View {
    @EnvironmentObject private var onboard: OnboardState

    var body: some View {
        OnboardingStepScreen(
            step: .trialGift,
            title: "",
            subtitle: "",
            layoutStyle: .minimalCentered
        ) {
            OnboardingTrialMessage(
                icon: "gift.fill",
                title: "Congratulations!",
                bodyText: "Just for you, 7 days of Snap Second Pro for free."
            )
        } footer: {
            OnboardingPrimaryButton(title: "Continue") {
                onboard.advance()
            }
        }
    }
}

struct OnboardingTrialHowItWorksScreen: View {
    @EnvironmentObject private var onboard: OnboardState

    var body: some View {
        OnboardingStepScreen(
            step: .trialHowItWorks,
            title: "",
            subtitle: "",
            layoutStyle: .minimalCentered
        ) {
            OnboardingTrialMessage(
                icon: "bell.fill",
                title: "We'll remind you 1 day before your trial ends",
                bodyText: "No surprises, no pressure."
            )
        } footer: {
            OnboardingPrimaryButton(title: "Continue") {
                onboard.advance()
            }
        }
    }
}

struct OnboardingTrialClaimScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var clipStore: ClipStore
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    @State private var isClaiming = false
    private let benefits = [
        "Unlimited journals",
        "Music",
        "HD export",
        "Advanced editing",
        "Cloud backup",
        "Watermark control"
    ]

    var body: some View {
        OnboardingStepScreen(
            step: .trialClaim,
            title: "",
            subtitle: "",
            layoutStyle: .minimalCentered
        ) {
            VStack(spacing: 24) {
                StoryFunnelLogoBadge(imageName: "SplashLogo")

                Text("What you'll get")
                    .font(OnboardingTypography.fixed(isCondensedLayout ? 30 : 34, weight: .bold))
                    .foregroundStyle(T.core.text)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(benefits, id: \.self) { benefit in
                        OnboardingTrialChecklistRow(text: benefit)
                    }
                }
                .frame(maxWidth: 260)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            OnboardingPrimaryButton(title: isClaiming ? "Opening your offer..." : "Try for free") {
                guard !isClaiming else { return }
                isClaiming = true
                onboard.claimTrial(projectStore: projectStore, clipStore: clipStore)
            }
        }
    }
}

private struct OnboardingTrialMessage: View {
    let icon: String
    let title: String
    let bodyText: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        VStack(spacing: 28) {
            OnboardingTrialHeroSymbol(icon: icon)

            VStack(spacing: 14) {
                Text(title)
                    .font(OnboardingTypography.fixed(isCondensedLayout ? 30 : 34, weight: .bold))
                    .foregroundStyle(T.core.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)

                Text(bodyText)
                    .font(OnboardingTypography.preferred(.body, weight: .regular))
                    .foregroundStyle(T.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingTrialHeroSymbol: View {
    let icon: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        ZStack {
            Circle()
                .fill(T.primaryMuted.opacity(0.85))
                .frame(width: isCondensedLayout ? 108 : 124, height: isCondensedLayout ? 108 : 124)

            Circle()
                .stroke(T.border.opacity(0.8), lineWidth: 1)
                .frame(width: isCondensedLayout ? 108 : 124, height: isCondensedLayout ? 108 : 124)

            Image(systemName: icon)
                .font(.system(size: isCondensedLayout ? 44 : 52, weight: .semibold))
                .foregroundStyle(T.core.accent)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.08), radius: 12, y: 6)
    }
}

private struct OnboardingTrialChecklistRow: View {
    let text: String

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(T.core.text)
                .frame(width: 24, height: 24)

            Text(text)
                .font(OnboardingTypography.preferred(.headline, weight: .regular))
                .foregroundStyle(T.core.text)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

enum OnboardingStepScreenLayoutStyle {
    case standard
    case minimalCentered
}

private struct OnboardingFullscreenResponsiveScreen<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(proxy.size.height - 56, 0), alignment: .center)
                }
                .padding(.horizontal, isCondensedLayout ? 20 : 24)
                .padding(.top, isCondensedLayout ? 20 : 28)
                .padding(.bottom, isCondensedLayout ? 144 : 160)
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer
                .padding(.horizontal, isCondensedLayout ? 20 : 24)
                .padding(.top, isCondensedLayout ? 12 : 14)
                .padding(.bottom, isCondensedLayout ? 16 : 20)
        }
        .background(T.core.surface.ignoresSafeArea())
    }
}

struct OnboardingStepScreen<Content: View, Footer: View>: View {
    let step: OnboardingStep
    let title: String
    let subtitle: String
    let layoutStyle: OnboardingStepScreenLayoutStyle
    let content: Content
    let footer: Footer

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var onboard: OnboardState
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var usesStoryFunnel: Bool { onboard.usesStoryFunnel }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }
    private var shellTopPadding: CGFloat {
        if step == .previewGenerating {
            return isCondensedLayout ? 20 : 30
        }
        return isCondensedLayout ? 10 : 18
    }
    private var contentTopPadding: CGFloat {
        if step == .previewGenerating {
            return isCondensedLayout ? 52 : 76
        }
        return isCondensedLayout ? 18 : 24
    }
    private var bodySpacing: CGFloat {
        if step == .previewGenerating {
            return isCondensedLayout ? 18 : 20
        }
        return isCondensedLayout ? 20 : 24
    }
    private var usesMinimalCenteredLayout: Bool { layoutStyle == .minimalCentered }
    private var contentHorizontalAlignment: HorizontalAlignment {
        if usesMinimalCenteredLayout {
            return .center
        }
        return usesStoryFunnel ? .center : .leading
    }
    private var contentFrameAlignment: Alignment {
        usesMinimalCenteredLayout ? .center : (usesStoryFunnel ? .center : .leading)
    }
    private var resolvedContentTopPadding: CGFloat {
        if usesMinimalCenteredLayout {
            return isCondensedLayout ? 28 : 40
        }
        return contentTopPadding
    }
    private var resolvedBodySpacing: CGFloat {
        if usesMinimalCenteredLayout {
            return isCondensedLayout ? 28 : 36
        }
        return bodySpacing
    }
    private var resolvedBottomPadding: CGFloat {
        usesMinimalCenteredLayout
            ? (isCondensedLayout ? 140 : 148)
            : (isCondensedLayout ? 152 : 164)
    }

    init(
        step: OnboardingStep,
        title: String,
        subtitle: String,
        layoutStyle: OnboardingStepScreenLayoutStyle = .standard,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.step = step
        self.title = title
        self.subtitle = subtitle
        self.layoutStyle = layoutStyle
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: contentHorizontalAlignment, spacing: resolvedBodySpacing) {
                        if !usesMinimalCenteredLayout {
                            VStack(alignment: contentHorizontalAlignment, spacing: subtitle.isEmpty ? 0 : 12) {
                                Text(title)
                                    .font(OnboardingTypography.fixed(isCondensedLayout ? 26 : 30, weight: .bold))
                                    .foregroundStyle(T.core.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(usesStoryFunnel ? .center : .leading)

                                if !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(OnboardingTypography.preferred(.body, weight: .regular))
                                        .foregroundStyle(T.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(usesStoryFunnel ? .center : .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: contentFrameAlignment)
                        }

                        content
                            .frame(maxWidth: .infinity, alignment: contentFrameAlignment)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: usesMinimalCenteredLayout ? max(proxy.size.height - 56, 0) : 0,
                        alignment: usesMinimalCenteredLayout ? .center : .top
                    )
                    .padding(.horizontal, isCondensedLayout ? 20 : 24)
                    .padding(.top, resolvedContentTopPadding)
                    .padding(.bottom, resolvedBottomPadding)
                }
            }
        }
        .safeAreaPadding(.top, shellTopPadding)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                footer
                    .padding(.horizontal, isCondensedLayout ? 20 : 24)
                    .padding(.top, isCondensedLayout ? 12 : 14)
                    .padding(.bottom, isCondensedLayout ? 16 : 20)
            }
        }
        .background(T.core.surface.ignoresSafeArea())
    }
}

struct StoryFunnelBadge: View {
    let icon: String
    let accent: Color

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.82))
                .frame(width: isCondensedLayout ? 76 : 88, height: isCondensedLayout ? 76 : 88)

            Circle()
                .stroke(accent.opacity(0.95), lineWidth: 3)
                .frame(width: isCondensedLayout ? 86 : 98, height: isCondensedLayout ? 86 : 98)

            Image(systemName: icon)
                .font(.system(size: isCondensedLayout ? 26 : 30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
    }
}

private struct StoryFunnelLogoBadge: View {
    let imageName: String

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: isCondensedLayout ? 88 : 104, height: isCondensedLayout ? 88 : 104)
            .accessibilityLabel("Snap Second")
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, isCondensedLayout ? 14 : 16)
        }
        .background(T.core.accent)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, isCondensedLayout ? 14 : 16)
        }
        .background(T.surfaceAlt)
        .foregroundStyle(T.core.text)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }
}

struct OnboardingBadge: View {
    let title: String
    var accent = false

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    var body: some View {
        Text(title)
            .font(OnboardingTypography.fixed(12, weight: .bold))
            .foregroundStyle(accent ? .white : T.core.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule(style: .continuous)
                    .fill(accent ? T.core.accent : T.surfaceAlt)
            }
            .overlay {
                if !accent {
                    Capsule(style: .continuous)
                        .stroke(T.border, lineWidth: 1)
                }
            }
    }
}

struct OnboardingStatCard: View {
    let value: String
    let label: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(OnboardingTypography.fixed(isCondensedLayout ? 24 : 28, weight: .bold))
                .foregroundStyle(T.core.text)

            Text(label)
                .font(OnboardingTypography.preferred(.footnote, weight: .semibold))
                .foregroundStyle(T.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: isCondensedLayout ? 88 : 96, alignment: .leading)
        .padding(isCondensedLayout ? 16 : 18)
        .background(T.core.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }
}

struct OnboardingMiniFeatureRow: View {
    let icon: String
    let title: String
    let bodyText: String

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    init(icon: String, title: String, body: String) {
        self.icon = icon
        self.title = title
        self.bodyText = body
    }

    var bodyView: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(T.core.accent)
                .frame(width: 40, height: 40)
                .background(T.primaryMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(OnboardingTypography.preferred(.headline, weight: .semibold))
                    .foregroundStyle(T.core.text)

                Text(bodyText)
                    .font(OnboardingTypography.preferred(.callout, weight: .regular))
                    .foregroundStyle(T.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(T.core.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }

    var body: some View {
        bodyView
    }
}

struct OnboardingNumberedStepCard: View {
    let number: String
    let title: String
    let bodyText: String

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    init(number: String, title: String, body: String) {
        self.number = number
        self.title = title
        self.bodyText = body
    }

    var bodyView: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(OnboardingTypography.fixed(12, weight: .bold))
                .foregroundStyle(T.core.accent)
                .frame(width: 44, height: 44)
                .background(T.primaryMuted, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(OnboardingTypography.preferred(.headline, weight: .semibold))
                    .foregroundStyle(T.core.text)

                Text(bodyText)
                    .font(OnboardingTypography.preferred(.callout, weight: .regular))
                    .foregroundStyle(T.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(T.surfaceAlt, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    var body: some View {
        bodyView
    }
}

struct OnboardingQuoteCard: View {
    let quote: String
    let caption: String

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(T.core.accent)

            Text("“\(quote)”")
                .font(OnboardingTypography.preferred(.body, weight: .medium))
                .foregroundStyle(T.core.text)
                .fixedSize(horizontal: false, vertical: true)

            Text(caption)
                .font(OnboardingTypography.preferred(.footnote, weight: .regular))
                .foregroundStyle(T.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(T.core.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }
}

private struct OnboardingInfoPill: View {
    let icon: String
    let title: String
    let bodyText: String

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    var bodyView: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(T.core.primary)
                .frame(width: 40, height: 40)
                .background(T.primaryMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(OnboardingTypography.preferred(.headline, weight: .semibold))
                    .foregroundStyle(T.core.text)

                Text(bodyText)
                    .font(OnboardingTypography.preferred(.callout, weight: .regular))
                    .foregroundStyle(T.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(T.core.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(T.border, lineWidth: 1)
        )
    }

    var body: some View {
        bodyView
    }
}
