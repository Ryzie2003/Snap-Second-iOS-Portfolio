import SwiftUI
import UIKit

struct AppScreenStyle: ViewModifier {
    let T: Theme
    func body(content: Content) -> some View {
        content
            .background(T.core.surface) // matches Projects/Calendar surfaces  :contentReference[oaicite:3]{index=3}
            .scrollContentBackground(.hidden)
    }
}
extension View {
    func appScreenStyle(_ T: Theme) -> some View { modifier(AppScreenStyle(T: T)) }
}

struct AppTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .foregroundStyle(.primary)
    }
}
extension View {
    func appTitleStyle(_ _: Theme) -> some View { modifier(AppTitleStyle()) }
}

struct AppSectionTitleStyle: ViewModifier {
    let fontSize: CGFloat?

    func body(content: Content) -> some View {
        let base = UIFont.preferredFont(forTextStyle: .title3).pointSize

        return content
            .font(
                .system(
                    size: fontSize ?? base,
                    weight: .semibold,
                    design: .rounded
                )
            )
            .foregroundStyle(.primary)
    }
}

extension View {
    /// Optional fontSize keeps old call sites working (Settings, Rewind, etc.).
    func appSectionTitleStyle(_ _: Theme, fontSize: CGFloat? = nil) -> some View {
        modifier(AppSectionTitleStyle(fontSize: fontSize))
    }
}


struct CardBackground: ViewModifier {
    let T: Theme
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(T.core.surface) // subtle card surface  :contentReference[oaicite:4]{index=4}
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(T.border, lineWidth: 1) // thin keyline like ProjectsView  :contentReference[oaicite:5]{index=5}
            )
    }
}
extension View {
    func appCard(_ T: Theme) -> some View { modifier(CardBackground(T: T)) }
}
