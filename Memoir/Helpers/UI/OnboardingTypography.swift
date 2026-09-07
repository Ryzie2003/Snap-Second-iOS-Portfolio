import SwiftUI
import UIKit

enum OnboardingTypography {
    private static func fontName(for weight: Font.Weight) -> String {
        if weight == .bold || weight == .heavy || weight == .black {
            return "MavenPro-Bold"
        }
        if weight == .semibold {
            return "MavenPro-SemiBold"
        }
        if weight == .medium {
            return "MavenPro-Medium"
        }
        return "MavenPro-Regular"
    }

    static func scaled(_ size: CGFloat, screenHeight: CGFloat = UIScreen.main.bounds.height) -> CGFloat {
        OnboardingLayout.scaledFontSize(size, screenHeight: screenHeight)
    }

    static func fixed(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(fontName(for: weight), size: scaled(size))
    }

    static func preferred(_ textStyle: UIFont.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom(
            fontName(for: weight),
            size: scaled(UIFont.preferredFont(forTextStyle: textStyle).pointSize)
        )
    }
}
