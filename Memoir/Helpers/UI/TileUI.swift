import SwiftUI

/// A lightweight card container that adapts to light/dark mode without Assets.
/// Usage: `Tile { ... }`  (or `Tile(theme: T) { ... }` to use your Theme colors)
struct Tile<Content: View>: View {
    // Style
    var cornerRadius: CGFloat
    var padding: CGFloat
    var background: Color
    var border: Color
    var shadowRadius: CGFloat

    // Content
    @ViewBuilder var content: () -> Content

    // Env
    @Environment(\.colorScheme) private var scheme

    /// Base initializer with fully custom colors (defaults are dynamic system colors).
    init(
        cornerRadius: CGFloat = 20,
        padding: CGFloat = 0,
        background: Color = Color(UIColor.secondarySystemBackground),
        border: Color = Color(UIColor.separator),
        shadowRadius: CGFloat = 12,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.background = background
        self.border = border
        self.shadowRadius = shadowRadius
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(
                color: scheme == .dark
                    ? Color.white.opacity(0.06)
                    : Color.black.opacity(0.10),
                radius: shadowRadius, y: 6
            )
    }
}

// MARK: - Convenience init to use your Theme (Theme/Core the way your CalendarView defines it)
extension Tile {
    /// Use your app Theme (e.g., `Tile(theme: T) { ... }` where `T` is `Theme`).
    init(
        theme: Theme,
        cornerRadius: CGFloat = 20,
        padding: CGFloat = 0,
        shadowRadius: CGFloat = 12,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            cornerRadius: cornerRadius,
            padding: padding,
            background: theme.core.surface,
            border: theme.textSecondary.opacity(0.28), // subtle hairline derived from theme
            shadowRadius: shadowRadius,
            content: content
        )
    }
}
