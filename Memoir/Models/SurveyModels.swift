import SwiftUI

// MARK: - Answers we collect
struct SurveyAnswers: Codable {
    // First question: "How did you hear about Memoir?"
    var discoverySource: String? = nil
    var startReason: String? = nil

    // Multi-select fields:
    var captureTopics: [String] = []
    var memoryFriction: [String] = []
    var supportNeeds: [String] = []
    var cadenceGoal: String? = nil
    var audienceIntent: String? = nil

    func isComplete(for variant: OnboardingExperimentVariant) -> Bool {
        _ = variant
        return (discoverySource?.isEmpty == false)
            && !captureTopics.isEmpty
            && !supportNeeds.isEmpty
    }
}



// MARK: - A single question
// Models.swift (or near SurveyFlow.swift)
struct SurveyQuestion {
    let title: String
    let subtitle: String?
    let options: [String]
    let kind: Kind
    let buttonTitle: String?

    enum Kind {
        case single(keyPath: WritableKeyPath<SurveyAnswers, String?>)
        case multi(keyPath: WritableKeyPath<SurveyAnswers, [String]>)
    }
}

enum SurveyPage {
    case question(step: OnboardingStep, question: SurveyQuestion)
    case interstitial(step: OnboardingStep, title: String, subtitle: String, buttonTitle: String)
    /// Full-screen break: no survey progress bar; title + subtitle + centered image (like survey intro).
    case interstitialBreak(step: OnboardingStep, title: String, subtitle: String, buttonTitle: String, imageName: String)
}


// MARK: - Palette
enum SurveyStyle {
    // primary CTA color
    static let cta = Color(hex: "#A8DADC")
    static let surface = Color(.systemGray6)
    static let text = Color.primary
}

// MARK: - Hex helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:(a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue:  Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}
