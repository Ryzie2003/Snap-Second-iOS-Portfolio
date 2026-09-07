import SwiftUI

/// Uses the same pill UI as other shelves (PillTextButton / PillButton)
struct StylesShelfVertical: View {
    let T: Theme
    @Binding var selected: MontageStyle
    var onChange: () -> Void

    init(T: Theme,
         selected: Binding<MontageStyle>,
         onChange: @escaping () -> Void) {
        self.T = T
        self._selected = selected
        self.onChange = onChange
    }

    var body: some View {
        // Match OrientationShelfVertical: vertical scroll + VStack spacing/padding
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {

                HStack(spacing: 10) {
                    PillTextButton("Classic", isOn: selected == .classic, T: T) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selected = .classic; onChange()
                    }

                    PillTextButton("Cinematic", isOn: selected == .cinematic, T: T) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selected = .cinematic; onChange()
                    }
                }

                HStack(spacing: 10) {
                    PillTextButton("Scrolling", isOn: selected == .scrolling, T: T) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selected = .scrolling; onChange()
                    }

                    PillTextButton("Timelapse", isOn: selected == .timelapse, T: T) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selected = .timelapse; onChange()
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}
