import SwiftUI

struct SurveyFlow: View {
    @EnvironmentObject var onboard: OnboardState
    let displayStep: OnboardingStep
    @State private var answers = SurveyAnswers()
    @State private var savingSurvey = false
    @State private var showSurveyThanks = false
    @State private var surveyError: String? = nil

    /// Driven by the step this view was created for so slide-out screens stay stable during transitions.
    private var index: Int {
        pageIndex(for: displayStep) ?? 0
    }

    private var variant: OnboardingExperimentVariant {
        onboard.sessionVariant
    }

    private var pages: [SurveyPage] {
        return [
            .question(
                step: .surveyQ1,
                question: SurveyQuestion(
                    title: "How did you hear about Snap Second?",
                    subtitle: nil,
                    options: [
                        "App Store search",
                        "TikTok or Instagram",
                        "Reddit or online community",
                        "Friend or family referral",
                        "YouTube or podcast",
                        "Other"
                    ],
                    kind: .single(keyPath: \.discoverySource),
                    buttonTitle: nil
                )
            ),
            .question(
                step: .surveyQ2,
                question: SurveyQuestion(
                    title: "What kinds of moments do you want to save with Snap Second?",
                    subtitle: nil,
                    options: [
                        "Everyday highlights",
                        "Family memories",
                        "Pets",
                        "Travel & adventures",
                        "School or college life",
                        "Special events & milestones"
                    ],
                    kind: .multi(keyPath: \.captureTopics),
                    buttonTitle: nil
                )
            ),
            .question(
                step: .surveyQ3,
                question: SurveyQuestion(
                    title: "Where could Snap Second support you the most?",
                    subtitle: nil,
                    options: [
                        "Daily habit",
                        "Remember little things",
                        "Track growth",
                        "Stay mindful",
                        "Organize stories",
                        "Spark creativity"
                    ],
                    kind: .multi(keyPath: \.supportNeeds),
                    buttonTitle: nil
                )
            )
        ]
    }

    var body: some View {
        Group {
            switch pages[index] {
            case let .question(_, question):
                SurveyScreen(
                    question: question,
                    index: index,
                    total: pages.count,
                    answers: $answers,
                    onContinue: advance,
                    onSkip: skip,
                    showsSkip: true,
                    showBack: index > 0,
                    onBack: goBack
                )

            case let .interstitial(_, title, subtitle, buttonTitle):
                SurveyInterstitialScreen(
                    title: title,
                    subtitle: subtitle,
                    buttonTitle: buttonTitle,
                    index: index,
                    total: pages.count,
                    onContinue: advance,
                    onSkip: skip,
                    showBack: index > 0,
                    onBack: goBack
                )

            case let .interstitialBreak(_, title, subtitle, buttonTitle, imageName):
                SurveyMidpointInterstitialScreen(
                    title: title,
                    subtitle: subtitle,
                    buttonTitle: buttonTitle,
                    imageName: imageName,
                    showBack: index > 0,
                    onBack: goBack,
                    onContinue: advance,
                    onSkip: skip
                )
            }
        }
        .onDisappear { persistIfDone() }
        .onAppear {
            answers = onboard.surveyAnswers
        }
    }

    private func goBack() {
        guard index > 0 else { return }
        onboard.recordSurveyAnswers(answers)
        onboard.navigate(to: step(for: index - 1))
    }

    private func advance() {
        if index < pages.count - 1 {
            onboard.recordSurveyAnswers(answers)
            onboard.navigate(to: step(for: index + 1))
        } else {
            persistIfDone()
            onboard.recordSurveyAnswers(answers)
            Task { await syncSurveyAnswers() }
            onboard.advanceFromSurvey()
        }
    }

    private func skip() {
        if index < pages.count - 1 {
            onboard.recordSurveyAnswers(answers)
            onboard.navigate(to: step(for: index + 1))
        } else {
            onboard.recordSurveyAnswers(answers)
            onboard.advanceFromSurvey()
        }
    }

    private func persistIfDone() {
        guard answers.isComplete(for: variant) else { return }
        if let data = try? JSONEncoder().encode(answers) {
            UserDefaults.standard.set(data, forKey: surveyStorageKey)
        }
    }

    @MainActor
    private func syncSurveyAnswers() async {
        guard answers.isComplete(for: variant) else { return }
        savingSurvey = true; surveyError = nil
        defer { savingSurvey = false }

        OnboardingAnalytics.trackSurveySubmitted(answers, variant: variant)

        do {
            if AnalyticsRollout.dualWriteLegacySurveyStorage {
                try await FirebaseSurveyService().saveSurvey(
                    version: OnboardingAnalytics.surveyVersion(for: variant),
                    answers: OnboardingAnalytics.legacySurveyAnswersPayload(from: answers),
                    overwrite: true
                )
            }
            showSurveyThanks = true
        } catch {
            surveyError = error.localizedDescription
            print("Survey save failed:", error.localizedDescription)
        }
    }

    private var surveyStorageKey: String {
        OnboardState.surveyStorageKey(for: variant)
    }

    private func step(for pageIndex: Int) -> OnboardingStep {
        switch pages[pageIndex] {
        case let .question(step, _), let .interstitial(step, _, _, _), let .interstitialBreak(step, _, _, _, _):
            return step
        }
    }

    private func pageIndex(for step: OnboardingStep) -> Int? {
        pages.firstIndex { page in
            switch page {
            case let .question(pageStep, _), let .interstitial(pageStep, _, _, _), let .interstitialBreak(pageStep, _, _, _, _):
                return pageStep == step
            }
        }
    }
}
