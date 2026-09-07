//
//  AssetImageFetchError.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/14/25.
//


import Photos

enum AssetImageFetchError: Error {
    case notImage, noData, timeout
}

/// Async image-data fetch for a PHAsset (downloads from iCloud if needed).
extension PHAsset {
    func requestImageData(timeout: TimeInterval = 90) async throws -> Data {
        guard mediaType == .image else { throw AssetImageFetchError.notImage }

        // Track the request ID for cancellation on timeout
        var requestID: PHImageRequestID?

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    let opts = PHImageRequestOptions()
                    opts.deliveryMode = .highQualityFormat
                    opts.isNetworkAccessAllowed = true
                    opts.version = .current

                    requestID = PHImageManager.default()
                        .requestImageDataAndOrientation(for: self, options: opts) { data, _, _, info in

                            if let cancelled = info?[PHImageCancelledKey] as? NSNumber, cancelled.boolValue {
                                cont.resume(throwing: CancellationError()); return
                            }
                            if let err = info?[PHImageErrorKey] as? Error {
                                cont.resume(throwing: err); return
                            }
                            guard let data = data else {
                                cont.resume(throwing: AssetImageFetchError.noData); return
                            }
                            cont.resume(returning: data)
                        }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AssetImageFetchError.timeout
            }

            // Return first successful result or throw first error
            guard let result = try await group.next() else {
                throw AssetImageFetchError.noData
            }
            group.cancelAll()

            // Cancel the PHImageManager request if it's still running
            if let rid = requestID {
                PHImageManager.default().cancelImageRequest(rid)
            }

            return result
        }
    }
}
