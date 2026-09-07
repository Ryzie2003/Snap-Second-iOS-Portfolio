//
//  AssetURLFetchError.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/14/25.
//


import Photos
import AVFoundation

enum AssetURLFetchError: Error {
    case notVideo, noAsset, exportFailed, timeout, exportSessionCreationFailed
}

extension PHAsset {
    /// Returns a local URL for the video backing this PHAsset.
    /// - Downloads from iCloud if needed (with 90 second timeout).
    /// - If the AVAsset is not a file-backed URL, exports to a temp .mov and returns that URL.
    func fileURL(timeout: TimeInterval = 90) async throws -> URL {
        guard mediaType == .video else { throw AssetURLFetchError.notVideo }

        // Track the request ID for cancellation on timeout
        var requestID: PHImageRequestID?

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    let opts = PHVideoRequestOptions()
                    opts.isNetworkAccessAllowed = true
                    opts.deliveryMode = .automatic

                    requestID = PHImageManager.default().requestAVAsset(forVideo: self, options: opts) { avAsset, _, info in
                        // Cancel/error cases
                        if let cancelled = info?[PHImageCancelledKey] as? NSNumber, cancelled.boolValue {
                            cont.resume(throwing: CancellationError()); return
                        }
                        if let err = info?[PHImageErrorKey] as? Error {
                            cont.resume(throwing: err); return
                        }
                        guard let asset = avAsset else {
                            cont.resume(throwing: AssetURLFetchError.noAsset); return
                        }

                        // Best case: file-backed asset
                        if let urlAsset = asset as? AVURLAsset {
                            cont.resume(returning: urlAsset.url); return
                        }

                        // Fallback: export to a temp file
                        let preset = AVAssetExportSession.exportPresets(compatibleWith: asset)
                            .contains(AVAssetExportPresetPassthrough)
                            ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality

                        let out = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("picker-\(UUID().uuidString).mov")

                        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                            cont.resume(throwing: AssetURLFetchError.exportSessionCreationFailed); return
                        }
                        session.outputURL = out
                        session.outputFileType = .mov
                        session.exportAsynchronously {
                            if session.status == .completed {
                                cont.resume(returning: out)
                            } else {
                                cont.resume(throwing: session.error ?? AssetURLFetchError.exportFailed)
                            }
                        }
                    }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AssetURLFetchError.timeout
            }

            // Return first successful result or throw first error
            guard let result = try await group.next() else {
                throw AssetURLFetchError.noAsset
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
