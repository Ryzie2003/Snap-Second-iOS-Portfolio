import SwiftUI

struct RangeShelfVertical: View {
    let T: Theme
    @Binding var rangeLabel: String
    let clipCount: Int

    let onChoosePreset: (Preset) -> Void
    let onChooseAll: () -> Void
    @Binding var showCustomPicker: Bool
    let onChooseMonths: (Set<Int>) -> Void
    let onChooseYears:  (Set<Int>) -> Void

    // Computed values for current month and year
    private var currentMonthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"  // full month name
        return formatter.string(from: Date())
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    // Which logical preset is currently active? These mirror MontageView's labels:
    //  - month  → rangeLabel == current month name (e.g. "November")
    //  - year   → rangeLabel == "2025"
    //  - all    → rangeLabel == "All"
    private var isMonthActive: Bool {
        rangeLabel == currentMonthName
    }

    private var isYearActive: Bool {
        rangeLabel == currentYear
    }

    private var isAllTimeActive: Bool {
        rangeLabel == "All"
    }

    private var isCustomActive: Bool {
        !(isMonthActive || isYearActive || isAllTimeActive)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            quickPresetsSection
        }
        .padding(.vertical, 8)
    }

    private var quickPresetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a range")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 4)

            // This Month (dynamic month name)
            largePresetButton(
                title: "This Month",
                subtitle: currentMonthName,
                isSelected: isMonthActive
            ) {
                onChoosePreset(.month)
            }

            // This Year (dynamic year)
            largePresetButton(
                title: "This Year",
                subtitle: currentYear,
                isSelected: isYearActive
            ) {
                onChoosePreset(.year)
            }

            // All Time
            largePresetButton(
                title: "All Time",
                subtitle: "All clips from this project",
                isSelected: isAllTimeActive
            ) {
                onChooseAll()
            }

            // Custom dates (part of presets)
            largePresetButton(
                title: "Custom dates",
                subtitle: "Pick an exact start and end date",
                isSelected: isCustomActive
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showCustomPicker = true
            }
        }
    }


    // MARK: - Helpers
    private func largePresetButton(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundColor(isSelected ? .white : .primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected
                          ? T.core.accent
                          : Color(UIColor.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected
                            ? T.core.accent.opacity(0.8)
                            : Color.primary.opacity(0.1),
                            lineWidth: 1)
            )
            .scaleEffect(isSelected ? 1.03 : 1.0)
            .shadow(color: isSelected ? T.core.accent.opacity(0.3) : .clear,
                    radius: isSelected ? 6 : 0,
                    x: 0, y: isSelected ? 2 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}



// Simple pill toggle used for month/year chips
private struct PillToggle: View {
    let title: String
    let isOn: Bool
    let theme: Theme

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                (isOn ? theme.core.primary.opacity(0.22) : theme.core.surface.opacity(0.7)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isOn ? 0.25 : 0.15), lineWidth: 1)
            )
    }
}
