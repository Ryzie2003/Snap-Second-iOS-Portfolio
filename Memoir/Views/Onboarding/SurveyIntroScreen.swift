import SwiftUI

private func surveyTopInset(for verticalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
    let safeAreaTop = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
        .keyWindow?.safeAreaInsets.top ?? 0
    return safeAreaTop + (OnboardingLayout.usesCondensedLayout(verticalSizeClass) ? 10 : 14)
}

struct SurveyIntroScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }
    private var horizontalPadding: CGFloat { isCondensedLayout ? 16 : 20 }
    private var titleTopPadding: CGFloat { isCondensedLayout ? 4 : 8 }

    var onContinue: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(T.core.accent.opacity(0.35))
                .frame(height: 3)
                .padding(.horizontal, 16)
                .opacity(0.35)

            HStack {
                Spacer()
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.textSecondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.top, isCondensedLayout ? 4 : 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Answer a few quick questions to help us personalize your experience.")
                    .font(OnboardingTypography.fixed(isCondensedLayout ? 20 : 22, weight: .semibold))
                    .foregroundStyle(T.core.text)
                    .padding(.top, titleTopPadding)
                    .padding(.horizontal, horizontalPadding)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: isCondensedLayout ? 12 : 16)

                Image("SurveyIntroImage")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: isCondensedLayout ? 250 : 420)
                    .accessibilityHidden(true)

                Spacer(minLength: isCondensedLayout ? 12 : 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: {
                onContinue()
            }) {
                Text("Let's Go")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCondensedLayout ? 14 : 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, isCondensedLayout ? 16 : 24)
            .padding(.bottom, isCondensedLayout ? 20 : 28)
        }
        .padding(.top, surveyTopInset(for: verticalSizeClass))
        .background(T.core.surface.ignoresSafeArea())
    }
}
