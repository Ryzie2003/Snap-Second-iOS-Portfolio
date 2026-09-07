import Photos

enum PhotosWarmup {
    /// Best-effort Photos warmup that NEVER triggers a permission prompt.
    /// Call this only after the app already has .authorized or .limited.
    static func primeLibrary() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        // Tiny no-op fetch to spin up Photos caches.
        let opts = PHFetchOptions()
        opts.fetchLimit = 1
        _ = PHAsset.fetchAssets(with: opts).firstObject
    }
}
