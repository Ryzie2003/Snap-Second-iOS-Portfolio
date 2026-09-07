import SwiftUI

enum JournalTypography {
    /// Main handwriting header
    static func header(_ size: CGFloat = 28) -> Font {
        .custom("Handlee-Regular", size: size, relativeTo: .largeTitle)
    }

    /// Handwritten accent text (e.g. dates, small labels)
    static func accent(_ size: CGFloat = 17) -> Font {
        .custom("Handlee-Regular", size: size, relativeTo: .body)
    }

    /// If you want a hybrid: SF for body
    static func body(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .regular, design: .rounded)
    }
}
