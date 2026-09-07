import SwiftUI
import PhosphorSwift

struct WatermarkShelfVertical: View {
    let T: Theme
    @Binding var brandingOn: Bool
    let onChange: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    PillTextButton("On", isOn: brandingOn, T: T) {
                        brandingOn = true
                        onChange()
                    }
                    PillButton(isOn: !brandingOn, T: T) {
                        HStack(spacing: 6) {
                            Ph.sparkle.fill
                                        .foregroundStyle(.yellow)
                                        .frame(width: 18, height: 18)
                            Text("Off")
                        }
                    } action: {
                        brandingOn = false
                        onChange()
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}
