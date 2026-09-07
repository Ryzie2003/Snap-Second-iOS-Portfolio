import SwiftUI

struct MontageControlsRow: View {
    let T: Theme
    @Binding var selectedTab: ControlTab

    // Tweak this if you ever need more/less width
    private let itemWidth: CGFloat = 96     // was ~equal-width; now wider so text doesn't clip
    private let itemHeight: CGFloat = 56
    var onTap: (ControlTab) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                controlItem(.range,       "calendar",        "Range")
                controlItem(.music,       "music.note",      "Music")
                controlItem(.captions,    "captions.bubble", "Captions")
                controlItem(.orientation, "crop.rotate",     "Orientation")
                controlItem(.quality, "square.and.arrow.up.on.square", "Quality")
                controlItem(.watermark,   "seal",            "Watermark")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 30)
        }
    }

    @ViewBuilder
    private func controlItem(_ tab: ControlTab, _ icon: String, _ title: String) -> some View {
            let isSel = (selectedTab == tab)

            return Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                selectedTab = tab            // always keep this tab selected
                onTap(tab)                   // ⬅️ always trigger sheet open
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                    Text(title)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(width: itemWidth, height: itemHeight)
                .foregroundStyle(isSel ? T.core.primary : T.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSel ? T.core.primary.opacity(0.12) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSel ? T.core.primary : T.border.opacity(0.6), lineWidth: isSel ? 1.25 : 1)
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }
