import SwiftUI

private func surveyTopInset(for verticalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
    let safeAreaTop = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
        .keyWindow?.safeAreaInsets.top ?? 0
    return safeAreaTop + (OnboardingLayout.usesCondensedLayout(verticalSizeClass) ? 10 : 14)
}

struct SurveyScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }
    private var contentHPadding: CGFloat { isCondensedLayout ? 16 : 24 }
    private var progressTopPadding: CGFloat { isCondensedLayout ? 12 : 18 }
    private var continueButtonTopPadding: CGFloat { isCondensedLayout ? 16 : 24 }
    private var continueButtonBottomPadding: CGFloat { isCondensedLayout ? 20 : 28 }

    @State private var selection: String? = nil            // for single
    @State private var multiSelection = Set<String>()      // for multi
    @State private var singleAdvanceToken = UUID()
    @State private var singleAdvanceTask: Task<Void, Never>?

    let question: SurveyQuestion
    let index: Int
    let total: Int
    @Binding var answers: SurveyAnswers
    var onContinue: () -> Void
    var onSkip: () -> Void
    var showsSkip: Bool = true

    // Back support
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Progress
            ProgressView(value: Double(index + 1), total: Double(total))
                .tint(T.core.accent)
                .padding(.horizontal, isCondensedLayout ? 20 : 28)
                .padding(.top, progressTopPadding)

            // Back / Skip row
            HStack {
                if showBack {
                    Button {
                        onBack?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                            Text("Back")
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Rectangle().fill(.clear).frame(width: 44, height: 28)
                }

                Spacer()

                if showsSkip {
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .foregroundStyle(T.textSecondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: isCondensedLayout ? 14 : 18) {
                    Text(question.title)
                        .font(OnboardingTypography.fixed(isCondensedLayout ? 28 : 32, weight: .bold))
                        .foregroundStyle(T.core.text)
                        .lineSpacing(2)
                        .padding(.top, isCondensedLayout ? 12 : 18)
                        .padding(.horizontal, contentHPadding)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if case .multi = question.kind {
                        Text("Select all that apply")
                            .font(OnboardingTypography.preferred(.subheadline, weight: .regular))
                            .foregroundStyle(T.textSecondary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, contentHPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(spacing: isCondensedLayout ? 10 : 12) {
                        switch question.kind {
                        case .single:
                            ForEach(question.options, id: \.self) { opt in
                                OptionRow(
                                    title: opt,
                                    isSelected: (selection ?? currentSingleValue) == opt,
                                    compact: isCondensedLayout,
                                    T: T
                                ) {
                                    selection = opt
                                    writeSingle(opt)
                                    scheduleSingleAdvance()
                                }
                                .padding(.horizontal, contentHPadding)
                            }

                        case .multi:
                            VStack(alignment: .leading, spacing: isCondensedLayout ? 10 : 12) {
                                ForEach(question.options, id: \.self) { opt in
                                    OptionRow(
                                        title: opt,
                                        isSelected: multiSelection.contains(opt),
                                        compact: isCondensedLayout,
                                        T: T
                                    ) {
                                        if multiSelection.contains(opt) {
                                            multiSelection.remove(opt)
                                        } else {
                                            multiSelection.insert(opt)
                                        }
                                        writeMulti(Array(multiSelection))
                                    }
                                    .padding(.horizontal, contentHPadding)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.bottom, {
                    switch question.kind {
                    case .single:
                        return isCondensedLayout ? 28 : 36
                    case .multi:
                        return isCondensedLayout ? 88 : 100
                    }
                }())
            }

            if case .multi = question.kind {
                Button(action: {
                    writeMulti(Array(multiSelection))
                    onContinue()
                }) {
                    Text(question.buttonTitle ?? "Continue")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, isCondensedLayout ? 14 : 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(multiSelection.isEmpty && currentMultiValue.isEmpty)
                .background(
                    (multiSelection.isEmpty && currentMultiValue.isEmpty)
                        ? T.core.accent.opacity(0.45)
                        : T.core.accent
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, contentHPadding)
                .padding(.top, continueButtonTopPadding)
                .padding(.bottom, continueButtonBottomPadding)
            }
        }
        .onAppear {
            switch question.kind {
            case .single:
                selection = currentSingleValue
                multiSelection = []
            case .multi:
                selection = nil
                multiSelection = Set(currentMultiValue)
            }
        }
        .onDisappear {
            singleAdvanceTask?.cancel()
            singleAdvanceTask = nil
        }
        .padding(.top, surveyTopInset(for: verticalSizeClass))
        .background(T.core.surface.ignoresSafeArea())
    }

    private func scheduleSingleAdvance() {
        singleAdvanceTask?.cancel()
        let token = UUID()
        singleAdvanceToken = token
        singleAdvanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, singleAdvanceToken == token else { return }
            onContinue()
            singleAdvanceTask = nil
        }
    }

    private var currentSingleValue: String {
        if case let .single(keyPath) = question.kind {
            return answers[keyPath: keyPath] ?? ""
        }
        return ""
    }

    private var currentMultiValue: [String] {
        if case let .multi(keyPath) = question.kind {
            return answers[keyPath: keyPath]
        }
        return []
    }

    private func writeSingle(_ value: String) {
        guard case let .single(keyPath) = question.kind, !value.isEmpty else { return }
        answers[keyPath: keyPath] = value
    }

    private func writeMulti(_ values: [String]) {
        guard case let .multi(keyPath) = question.kind else { return }
        answers[keyPath: keyPath] = values
    }
}

/// Survey midpoint only: matches survey intro rhythm (accent strip, title + copy, centered art, CTA). No progress bar.
struct SurveyMidpointInterstitialScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }
    private var horizontalPadding: CGFloat { isCondensedLayout ? 16 : 20 }
    private var titleTopPadding: CGFloat { isCondensedLayout ? 4 : 8 }
    private var continueButtonTopPadding: CGFloat { isCondensedLayout ? 16 : 24 }
    private var continueButtonBottomPadding: CGFloat { isCondensedLayout ? 20 : 28 }

    let title: String
    let subtitle: String
    let buttonTitle: String
    let imageName: String
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil
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
                if showBack {
                    Button {
                        onBack?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                            Text("Back")
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Rectangle().fill(.clear).frame(width: 44, height: 28)
                }

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
            }
            .padding(.trailing, 8)
            .padding(.top, isCondensedLayout ? 4 : 8)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(OnboardingTypography.fixed(isCondensedLayout ? 20 : 22, weight: .semibold))
                    .foregroundStyle(T.core.text)
                    .padding(.top, titleTopPadding)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OnboardingTypography.preferred(.body, weight: .regular))
                        .foregroundStyle(T.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }

                Spacer(minLength: isCondensedLayout ? 12 : 16)

                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: isCondensedLayout ? 250 : 420)
                    .accessibilityHidden(true)

                Spacer(minLength: isCondensedLayout ? 12 : 16)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(action: onContinue) {
                Text(buttonTitle)
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
            .padding(.top, continueButtonTopPadding)
            .padding(.bottom, continueButtonBottomPadding)
        }
        .padding(.top, surveyTopInset(for: verticalSizeClass))
        .background(T.core.surface.ignoresSafeArea())
    }
}

struct SurveyInterstitialScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var T: Theme { AppTheme.sunsetGlow.theme(for: scheme) }

    private var isCondensedLayout: Bool { OnboardingLayout.usesCondensedLayout(verticalSizeClass) }
    private var continueButtonTopPadding: CGFloat { isCondensedLayout ? 16 : 24 }
    private var continueButtonBottomPadding: CGFloat { isCondensedLayout ? 20 : 28 }

    let title: String
    let subtitle: String
    let buttonTitle: String
    let index: Int
    let total: Int
    var onContinue: () -> Void
    var onSkip: () -> Void
    var showBack: Bool = false
    var onBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(index + 1), total: Double(total))
                .tint(T.core.accent)
                .padding(.horizontal, isCondensedLayout ? 20 : 28)
                .padding(.top, isCondensedLayout ? 12 : 18)

            HStack {
                if showBack {
                    Button {
                        onBack?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                            Text("Back")
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Rectangle().fill(.clear).frame(width: 44, height: 28)
                }

                Spacer()

                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(T.textSecondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)

            Spacer(minLength: 0)

            ScrollView {
                VStack(spacing: isCondensedLayout ? 16 : 20) {
                    ZStack {
                        Circle()
                            .fill(T.primaryMuted)
                            .frame(width: isCondensedLayout ? 76 : 92, height: isCondensedLayout ? 76 : 92)

                        Image(systemName: "sparkles")
                            .font(.system(size: isCondensedLayout ? 30 : 36, weight: .semibold))
                            .foregroundStyle(T.core.accent)
                    }
                    .padding(.top, isCondensedLayout ? 8 : 0)

                    Text(title)
                        .font(OnboardingTypography.fixed(isCondensedLayout ? 30 : 36, weight: .bold))
                        .foregroundStyle(T.core.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, isCondensedLayout ? 16 : 24)
                        .fixedSize(horizontal: false, vertical: true)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(OnboardingTypography.preferred(.title3, weight: .regular))
                            .foregroundStyle(T.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, isCondensedLayout ? 20 : 32)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            Button(action: onContinue) {
                Text(buttonTitle)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCondensedLayout ? 14 : 16)
            }
            .buttonStyle(.plain)
            .background(T.core.accent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, isCondensedLayout ? 16 : 24)
            .padding(.top, continueButtonTopPadding)
            .padding(.bottom, continueButtonBottomPadding)
        }
        .padding(.top, surveyTopInset(for: verticalSizeClass))
        .background(T.core.surface.ignoresSafeArea())
    }
}

// A pill-shaped toggle chip
private struct Chip: View {
    let title: String
    let isOn: Bool
    let T: Theme
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .foregroundStyle(isOn ? .white : T.core.text)
                .background(
                    Capsule().fill(isOn ? T.core.accent : T.core.text.opacity(0.08))
                )
                .overlay(
                    Capsule().stroke(T.border, lineWidth: isOn ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// A tiny flow layout for chips
private struct FlowWrap<Content: View>: View {
    let spacing: CGFloat
    let runSpacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 8, runSpacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.runSpacing = runSpacing
        self.content = content()
    }

    var body: some View {
        var width: CGFloat = 0
        var height: CGFloat = 0

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                content
                    .fixedSize()
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > geo.size.width {
                            width = 0
                            height -= d.height + runSpacing
                        }
                        let result = width
                        width -= d.width + spacing
                        return result
                    }
                    .alignmentGuide(.top) { d in
                        let result = height
                        return result
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 0)
    }
}


// MARK: - Option Row
private struct OptionRow: View {
    let title: String
    let isSelected: Bool
    var compact: Bool = false
    let T: Theme
    let tap: () -> Void

    init(title: String, isSelected: Bool, compact: Bool = false, T: Theme, tap: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.compact = compact
        self.T = T
        self.tap = tap
    }

    var body: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: compact ? 12 : 14) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? T.core.primary : T.textSecondary.opacity(0.35), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if isSelected {
                        Circle()
                            .fill(T.core.primary)
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 2)

                Text(title)
                    .foregroundStyle(T.core.text)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 12 : 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? T.core.primary.opacity(0.14) : T.core.surface.mix(with: T.core.primary, amount: 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isSelected ? T.core.primary.opacity(0.95) : T.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
