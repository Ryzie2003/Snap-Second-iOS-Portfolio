import SwiftUI
import PhosphorSwift

struct FiltersShelfVertical: View {
    let T: Theme
    @Binding var selectedFilter: MontageFilter
    let onChange: () -> Void

    var body: some View {
        let pillWidth: CGFloat = 148
        let interColumnSpacing: CGFloat = 8
        let twoCols = [
            GridItem(.fixed(pillWidth), spacing: interColumnSpacing, alignment: .center),
            GridItem(.fixed(pillWidth), spacing: interColumnSpacing, alignment: .center)
        ]

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .center, spacing: 12) {
                LazyVGrid(columns: twoCols, alignment: .center, spacing: 10) {
                    ForEach(MontageFilter.allCases) { filter in
                        filterPill(for: filter, pillWidth: pillWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func filterPill(for filter: MontageFilter, pillWidth: CGFloat) -> some View {
        PillButton(isOn: filter == selectedFilter, T: T) {
            Text(filter.displayName)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .center)
        } action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedFilter = filter
            onChange()
        }
        .frame(width: pillWidth)
    }
}
