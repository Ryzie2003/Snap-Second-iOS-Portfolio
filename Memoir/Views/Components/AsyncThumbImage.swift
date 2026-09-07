import SwiftUI
import UIKit

struct AsyncThumbImage: View {
    let data: Data
    let key: String

    @State private var uiImage: UIImage?
    @State private var isVisible: Bool

    init(data: Data, key: String) {
        self.data = data
        self.key = key
        let initialImage = ThumbCache.shared.image(for: key, data: data)
        _uiImage = State(initialValue: initialImage)
        _isVisible = State(initialValue: initialImage != nil)
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(isVisible ? 1 : 0)
            } else {
                Color.clear
            }
        }
        .onAppear { load() }
        .onChange(of: key) { _, _ in load() }
    }

    private func load() {
        if let cached = ThumbCache.shared.image(for: key) {
            uiImage = cached
            isVisible = true
        } else {
            ThumbCache.shared.decode(data, key: key) { img in
                guard let img else { return }
                uiImage = img
                isVisible = false
                withAnimation(.easeOut(duration: 0.2)) {
                    isVisible = true
                }
            }
        }
    }
}
