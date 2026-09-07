import SwiftUI

struct SpeedShelfVertical: View {
    @Binding var speed: Double
    let onChange: () -> Void

    private let minSpeed: Double = 0.5
    private let maxSpeed: Double = 5.0
    private let step: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Speed")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text("\(speed, specifier: "%.1f")×")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { speed },
                        set: { newValue in
                            let stepped = (newValue / step).rounded() * step
                            speed = min(max(stepped, minSpeed), maxSpeed)
                        }
                    ),
                    in: minSpeed...maxSpeed
                ) { editing in
                    // Only trigger rebuild when user finishes dragging
                    if !editing {
                        onChange()
                    }
                }
            }

            Text("Applies to the entire montage")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }
}
