import UIKit

final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "thumb.decode", qos: .userInitiated)

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func image(for key: String, data: Data) -> UIImage? {
        if let img = cache.object(forKey: key as NSString) {
            return img
        }

        guard let img = Self.displayReadyImage(from: data) else {
            return nil
        }

        cache.setObject(img, forKey: key as NSString)
        return img
    }

    func predecode(_ items: [(data: Data, key: String)]) async {
        guard !items.isEmpty else { return }

        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                for item in items where self.cache.object(forKey: item.key as NSString) == nil {
                    if let img = Self.displayReadyImage(from: item.data) {
                        self.cache.setObject(img, forKey: item.key as NSString)
                    }
                }

                continuation.resume()
            }
        }
    }

    func decode(_ data: Data, key: String, completion: @escaping (UIImage?) -> Void) {
        if let img = cache.object(forKey: key as NSString) {
            completion(img); return
        }
        queue.async { [weak self] in
            let img = Self.displayReadyImage(from: data)       // small, already-downsampled blobs
            if let img { self?.cache.setObject(img, forKey: key as NSString) }
            DispatchQueue.main.async { completion(img) }
        }
    }

    private static func displayReadyImage(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
