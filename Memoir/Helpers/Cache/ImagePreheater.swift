import Photos
import UIKit

final class ImagePreheater {
    static let shared = ImagePreheater()
    private let manager = PHCachingImageManager()

    /// Preheat thumbnails for the given assets at about "cell size" for snappy first paints.
    func preheat(_ assets: [PHAsset], pointSize: CGFloat = 160) {
        let scale = UIScreen.main.scale
        let target = CGSize(width: pointSize * scale, height: pointSize * scale)
        manager.startCachingImages(for: assets, targetSize: target, contentMode: .aspectFill, options: nil)
    }
}
