import SwiftUI

struct OnboardingVideoScreen: View {
    @EnvironmentObject private var onboard: OnboardState

    let primary: Color
    let accent: Color

    @Environment(\.colorScheme) private var scheme
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private let loopLength: TimeInterval = 15.7
    @State private var startDate = Date()

    private var loopTime: TimeInterval {
        let elapsed = Date().timeIntervalSince(startDate)
        let t = fmod(elapsed, loopLength)
        return t >= 0 ? t : (t + loopLength)
    }

    // Blur only for the intro; strong hold, then slow fade out
    private func blurRadius(for t: TimeInterval) -> CGFloat {
        let intro: Double = 6.0        // total duration of blur effect
        let hold: Double = 2.0         // keep full blur for first 2s
        let maxBlur: CGFloat = 16.0    // increase intensity a bit

        if t <= hold { return maxBlur }
        if t >= intro { return 0 }

        // Linear fade from hold → intro
        let progress = (t - hold) / (intro - hold)
        return maxBlur * (1 - progress)
    }


    var body: some View {
        ZStack {
            // 1) Background video with time-based blur
            TimelineView(.animation) { _ in
                LoopingPlayerView(videoName: "onboarding", videoExt: "mp4")
                    .blur(radius: blurRadius(for: loopTime))
                    .ignoresSafeArea()
            }

            // 2) Gradient on top of video (protects contrast)
            LinearGradient(
              colors: [
                T.core.surface.opacity(0.28), .clear, .clear,
                T.core.surface.opacity(0.40)
              ],
              startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // 3) Timed overlay beats (text stays sharp)
            TimelineView(.animation) { _ in
                OnboardingOverlay(time: loopTime, loopLength: loopLength)
            }

            // 4) Persistent bottom CTA
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Button(action: {
                        OnboardingAnalytics.trackWelcomeGetStartedTapped(variant: onboard.sessionVariant)
                        onboard.advance()
                    }) {
                        Text("Get Started")
                            .font(
                                .system(
                                    size: OnboardingTypography.scaled(18),
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(accent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.10),
                                    radius: 8, y: 4)

                    }
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("onboarding.getStarted")

                    Text("Every day is a story worth saving.")   // ← new tagline
                               .font(OnboardingTypography.fixed(14, weight: .regular))
                               .foregroundColor(.white.opacity(0.9))
                }
                .padding(.bottom, 28)
                .padding(.horizontal, 12)
                .background(Color.clear.ignoresSafeArea(edges: .bottom))
            }
        }
       .onAppear { startDate = Date() }
    }
}
private struct Logo: View {
    let accent: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {

        HStack(spacing: 8) {
            Image("WatermarkLogo")
              .resizable()
              .renderingMode(.original)
              .scaledToFit()                  // preserve aspect ratio
              .frame(height: 28)              // constrain one side only
              .fixedSize(horizontal: true, vertical: true) // belt & suspenders
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .shadow(
            color: scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.10),
            radius: 8, y: 4
        )
        .fixedSize() // extra safety if parent tries to squeeze
    }
}
