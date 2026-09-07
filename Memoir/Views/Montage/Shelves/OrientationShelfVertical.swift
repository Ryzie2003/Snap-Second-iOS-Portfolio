import SwiftUI
import PhosphorSwift


struct OrientationShelfVertical: View {
    let T: Theme
    @Binding var orientation: Orientation
    @Binding var contentMode: ContentMode
    let onChange: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    // Portrait — free
                    PillTextButton("Portrait", isOn: orientation == .v916, T: T) {
                        orientation = .v916; onChange()
                    }

                    // Landscape — free
                    PillTextButton("Landscape", isOn: orientation == .h169, T: T) {
                        orientation = .h169; onChange()
                    }

                    // Square - free
                    PillTextButton("Square", isOn: orientation == .s11, T: T) {
                        orientation = .s11; onChange()
                    }


                }

                HStack(spacing: 10) {
                    PillTextButton("Fit",  isOn: contentMode == .fit,  T: T) { contentMode = .fit;  onChange() }
                    PillTextButton("Fill", isOn: contentMode == .fill, T: T) { contentMode = .fill; onChange() }
                }
            }
            .padding(.vertical, 6)
        }
    }
}
