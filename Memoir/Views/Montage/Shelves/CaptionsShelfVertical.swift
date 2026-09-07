import SwiftUI
import PhosphorSwift

enum CaptionSelection: Equatable {
    case none
    case dates
    case custom
}

struct CaptionsShelfVertical: View {
    let T: Theme
    @Binding var captionMode: CaptionKind
    let isCustomCaptionsOn: Bool
    @Binding var customCaptionText: String
    @Binding var showDates: Bool
    let onChange: () -> Void

    @Binding var captionColor: Color
    @Binding var captionOpacity: Double
    @Binding var captionFontSize: Double
    @Binding var captionFont: CaptionFontVariant
    @Binding var captionPos: CaptionPos3

    @State private var showingCustomEditor: Bool = false

    private var currentSelection: CaptionSelection {
        if case .custom = captionMode {
            return .custom
        }
        if showDates || captionMode == .dateYear {
            return .dates
        }
        return .none
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                if showingCustomEditor && currentSelection == .custom {
                    customEditorView
                } else {
                    captionTypeSelector

                    if currentSelection == .dates {
                        tipView
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .safeAreaPadding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            if currentSelection == .custom {
                showingCustomEditor = true
            }
        }
    }

    private var captionTypeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Caption Style")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(T.textSecondary)
                .padding(.leading, 4)

            VStack(spacing: 8) {
                CaptionOptionRow(
                    title: "None",
                    icon: "xmark.circle",
                    description: "No captions on video",
                    isSelected: currentSelection == .none,
                    T: T
                ) {
                    selectCaptionType(.none)
                }

                CaptionOptionRow(
                    title: "Date Captions",
                    icon: "calendar",
                    description: "Show date & year on each clip",
                    isSelected: currentSelection == .dates,
                    T: T
                ) {
                    selectCaptionType(.dates)
                }

                CaptionOptionRow(
                    title: "Custom Text",
                    icon: "textformat",
                    description: "Add your own text overlay",
                    isSelected: currentSelection == .custom,
                    isPro: true,
                    T: T
                ) {
                    selectCaptionType(.custom)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingCustomEditor = true
                    }
                }
            }
        }
    }

    private var customEditorView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingCustomEditor = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(T.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(T.core.surface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Image(systemName: "textformat")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(T.core.accent)

                    Text("Custom Text")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(T.core.text)

                    Ph.sparkle.fill
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.yellow)
                }

                Spacer()
            }

            TextField("Enter caption", text: $customCaptionText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onChange(of: customCaptionText) { _ in onChange() }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CaptionFontVariant.allCases, id: \.self) { font in
                        FontButton(font: font, isSelected: captionFont == font, T: T) {
                            captionFont = font
                            onChange()
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(captionColor)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(T.border.opacity(0.5), lineWidth: 1)
                        )

                    ColorPicker("", selection: $captionColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: captionColor) { _ in onChange() }

                    ForEach([Color.white, Color.black, Color.yellow], id: \.self) { color in
                        Button {
                            captionColor = color
                            onChange()
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            captionColor == color ? T.core.accent : T.border.opacity(0.3),
                                            lineWidth: captionColor == color ? 2 : 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("A")
                        .font(.caption2)
                        .foregroundStyle(T.textSecondary)

                    Slider(value: $captionFontSize, in: 16...48, step: 2) { editing in
                        if !editing {
                            onChange()
                        }
                    }
                    .tint(T.core.accent)
                    .frame(width: 80)

                    Text("A")
                        .font(.body)
                        .foregroundStyle(T.textSecondary)
                }
            }
        }
        .transition(.opacity)
    }

    private var tipView: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(T.core.accent.opacity(0.7))

            Text("Dates appear automatically on each clip")
                .font(.caption2)
                .foregroundStyle(T.textSecondary)
                .lineLimit(2)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(T.core.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func selectCaptionType(_ selection: CaptionSelection) {
        switch selection {
        case .none:
            showDates = false
            captionMode = .none
            showingCustomEditor = false

        case .dates:
            showDates = true
            captionMode = .dateYear
            showingCustomEditor = false

        case .custom:
            showDates = false
            let text = customCaptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            customCaptionText = text
            captionMode = .custom(customCaptionText)
        }

        onChange()
    }
}

private struct CaptionOptionRow: View {
    let title: String
    let icon: String
    let description: String
    let isSelected: Bool
    var isPro: Bool = false
    let T: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? T.core.accent : T.border.opacity(0.5), lineWidth: 2)
                        .frame(width: 22, height: 22)

                    if isSelected {
                        Circle()
                            .fill(T.core.accent)
                            .frame(width: 12, height: 12)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isSelected)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? T.core.accent : T.textSecondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? T.core.text : T.textSecondary)

                        if isPro {
                            Ph.sparkle.fill
                                .frame(width: 12, height: 12)
                                .foregroundStyle(.yellow)
                        }
                    }

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(T.textSecondary.opacity(0.8))
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(T.core.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? T.core.accent.opacity(0.08) : T.core.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? T.core.accent.opacity(0.4) : T.border.opacity(0.15),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FontButton: View {
    let font: CaptionFontVariant
    let isSelected: Bool
    let T: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Aa")
                .font(fontPreview)
                .foregroundStyle(isSelected ? .white : T.core.text)
                .frame(width: 60, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? T.core.accent : T.core.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? T.core.accent : Color.clear, lineWidth: 2)
                )
                .overlay(
                    Text(fontLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(isSelected ? .white : T.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isSelected ? Color.black.opacity(0.3) : T.core.surface))
                        .offset(y: 18)
                )
        }
        .buttonStyle(.plain)
    }

    private var fontPreview: Font {
        switch font {
        case .system:
            return .system(size: 20, weight: .semibold)
        case .rounded:
            return .system(size: 20, weight: .semibold, design: .rounded)
        case .serif:
            return .system(size: 20, weight: .semibold, design: .serif)
        case .monospaced:
            return .system(size: 20, weight: .semibold, design: .monospaced)
        }
    }

    private var fontLabel: String {
        switch font {
        case .system:
            return "System"
        case .rounded:
            return "Rounded"
        case .serif:
            return "Serif"
        case .monospaced:
            return "Mono"
        }
    }
}
