import SwiftUI

struct OnboardingStoryIntroScreen: View {
    private struct Beat: Identifiable {
        let id: Int
        /// Single line of top copy (analytics + display for beats 2+).
        let title: String
        let buttonTitle: String
    }

    @EnvironmentObject private var onboard: OnboardState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let primary: Color
    let accent: Color

    @State private var beatIndex = 0

    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }
    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }

    private let beats: [Beat] = [
        Beat(
            id: 1,
            title: "The average person lives about 27,000 days.",
            buttonTitle: "Get Started"
        ),
        Beat(
            id: 2,
            title: "Sometimes the days blur together.",
            buttonTitle: "Continue"
        ),
        Beat(
            id: 3,
            title: "It's easy to forget the small, everyday moments.",
            buttonTitle: "Continue"
        ),
        Beat(
            id: 4,
            title: "Snap Second helps you turn those moments into your life movie.",
            buttonTitle: "Continue"
        )
    ]

    private var currentBeat: Beat {
        beats[beatIndex]
    }

    private var isFirstBeat: Bool { beatIndex == 0 }

    private var storyCopyHorizontalPadding: CGFloat { isCondensedLayout ? 18 : 24 }
    private var storyCopyBottomPadding: CGFloat { isCondensedLayout ? 96 : 126 }
    private var leadInFontSize: CGFloat { isCondensedLayout ? 18 : 20 }
    private var countFontSize: CGFloat { isCondensedLayout ? 32 : 38 }
    private var storyBeatFont: Font { OnboardingTypography.fixed(isCondensedLayout ? 22 : 28, weight: .semibold) }

    var body: some View {
        ZStack {
            LoopingPlayerView(videoName: "onboarding", videoExt: "mp4")
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.18),
                    .clear,
                    T.core.surface.opacity(0.20),
                    T.core.surface.opacity(0.82)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Group {
                if isFirstBeat {
                    VStack(spacing: isCondensedLayout ? 6 : 8) {
                        Text("The average person lives about")
                            .font(OnboardingTypography.fixed(leadInFontSize, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 4) {
                            AnimatedCountLine(show: true, fontSize: countFontSize, fontWeight: .semibold)
                            Text("days")
                                .font(OnboardingTypography.fixed(countFontSize, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                } else {
                        Text(currentBeat.title)
                            .font(storyBeatFont)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .minimumScaleFactor(0.82)
                            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 2)
                }
            }
            .padding(.horizontal, storyCopyHorizontalPadding)
            .padding(.bottom, storyCopyBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            VStack {
                Spacer()

                VStack(spacing: 10) {
                    Button(action: advanceBeat) {
                        Text(currentBeat.buttonTitle)
                            .font(
                                .system(
                                    size: OnboardingTypography.scaled(isCondensedLayout ? 17 : 18),
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .lineLimit(2)
                            .minimumScaleFactor(0.88)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, isCondensedLayout ? 14 : 16)
                            .background(accent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(
                                color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.10),
                                radius: 8,
                                y: 4
                            )
                    }
                    .padding(.horizontal, isCondensedLayout ? 16 : 20)
                    .accessibilityIdentifier(isFirstBeat ? "onboarding.getStarted" : "onboarding.storyIntro.continue")
                }
                .padding(.bottom, isCondensedLayout ? 16 : 28)
                .padding(.horizontal, isCondensedLayout ? 8 : 12)
                .background(Color.clear.ignoresSafeArea(edges: .bottom))
            }
        }
        .onAppear {
            trackCurrentBeatViewed()
        }
    }

    private func advanceBeat() {
        OnboardingAnalytics.trackStoryIntroBeatAdvanced(
            index: currentBeat.id,
            action: "continue_tap",
            variant: onboard.sessionVariant
        )

        if beatIndex < beats.count - 1 {
            beatIndex += 1
            trackCurrentBeatViewed()
            return
        }

        OnboardingAnalytics.trackWelcomeGetStartedTapped(variant: onboard.sessionVariant)
        onboard.advance()
    }

    private func trackCurrentBeatViewed() {
        OnboardingAnalytics.trackStoryIntroBeatViewed(
            index: currentBeat.id,
            title: currentBeat.title,
            variant: onboard.sessionVariant
        )
    }
}
