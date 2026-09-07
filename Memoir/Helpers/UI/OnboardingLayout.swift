import SwiftUI
import UIKit

enum OnboardingLayout {
    static func usesCondensedLayout(
        _ verticalSizeClass: UserInterfaceSizeClass?,
        screenHeight: CGFloat = UIScreen.main.bounds.height
    ) -> Bool {
        verticalSizeClass == .compact || LayoutScale.forScreenHeight(screenHeight) == .small
    }

    static func fontScale(screenHeight: CGFloat = UIScreen.main.bounds.height) -> CGFloat {
        switch LayoutScale.forScreenHeight(screenHeight) {
        case .small:
            return 0.92
        case .medium, .large:
            return 1
        }
    }

    static func scaledFontSize(
        _ size: CGFloat,
        screenHeight: CGFloat = UIScreen.main.bounds.height
    ) -> CGFloat {
        size * fontScale(screenHeight: screenHeight)
    }
}
