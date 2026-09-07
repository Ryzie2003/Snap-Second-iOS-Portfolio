import SwiftUI

public struct PillButton<Label: View>: View {
    public let isOn: Bool
    public let action: () -> Void
    public let label: () -> Label
    let T: Theme

    init(isOn: Bool = false, T: Theme, @ViewBuilder label: @escaping () -> Label, action: @escaping () -> Void) {
        self.isOn = isOn
        self.T = T
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label()
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(isOn ? T.core.primary : T.core.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .fixedSize(horizontal: true, vertical: false)
                .overlay(Capsule().stroke(isOn ? T.core.primary : T.border.opacity(0.75), lineWidth: 1))
                .background(isOn ? T.core.primary.opacity(0.16) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

public struct PillTextButton: View {
    public let title: String
    public let isOn: Bool
    let T: Theme
    public let action: () -> Void

    init(_ title: String, isOn: Bool = false, T: Theme, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.T = T
        self.action = action
    }

    public var body: some View {
        PillButton(isOn: isOn, T: T) { Text(title) } action: { action() }
    }
}
