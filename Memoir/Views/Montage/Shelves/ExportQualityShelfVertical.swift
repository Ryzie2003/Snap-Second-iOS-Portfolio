import SwiftUI
import PhosphorSwift

struct ExportQualityShelfVertical: View {
    let T: Theme
    @Binding var exportQuality: ExportQuality
    var onChange: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            // Centered title
            Text("Choose export resolution")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            // Two pills side-by-side, centered
            HStack(spacing: 10) {
                PillTextButton("Standard (720p)", isOn: exportQuality == .standard, T: T) {
                    exportQuality = .standard
                    onChange()
                }

                PillButton(isOn: exportQuality == .hd, T: T) {
                    HStack(spacing: 6) {
                        Ph.sparkle.fill
                                    .foregroundStyle(.yellow)
                                    .frame(width: 18, height: 18)
                        Text("HD (1080p)")
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                    }
                } action: {
                    exportQuality = .hd
                    onChange()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 4)
    }
}
