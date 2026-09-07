//
//  SmartFillEngine.swift
//

import Foundation
import Photos
import UIKit
import AVFoundation

@inline(__always)
private func onMain<T>(_ work: @MainActor () -> T) async -> T {
    await MainActor.run { work() }
}


/// Creates “filler” clips for every truly-empty day in a given month.
struct SmartFillEngine {

    private let store     = ClipStore.shared
    private let calendar  = Calendar.current
    private let fm        = FileManager.default

    // MARK: – Public entry point
    // PRIMARY: 4-arg progress (with thumbnail)
    @discardableResult
    func fillMissingDays(
        in range: ClosedRange<Date>,
        project: Project,
        duration: TimeInterval = ClipDefaults.duration,
        progress: @escaping (Int, Int, Date, UIImage?) -> Void
    ) async throws -> [Date: URL] {

        let month = calendar.startOfMonth(range.lowerBound)
        let targets = await holesThatHaveLibraryAssets(in: month, project: project)
        guard !targets.isEmpty else { return [:] }

        let orientationRaw = ClipDefaults.orientationRaw
        let mediaConfig = ClipDefaults.mediaConfig(for: orientationRaw)

        var results: [Date: URL] = [:]

        for (index, day) in targets.enumerated() {
            guard let asset = bestAsset(for: day) else { continue }

            // create clip + thumbnail (thumb is a UIImage)
            // actualDuration may be less than requested if video is shorter
            let (tmpClipURL, thumb, actualDuration) = try await makeClip(
                from: asset,
                duration: duration,
                mediaConfig: mediaConfig
            )

            // publish progress *before* Core Data write so HUD feels snappy
            DispatchQueue.main.async {
                progress(index + 1, targets.count, day, thumb)
            }

            await MainActor.run {
                store.addOrReplaceClip(
                    for: day,
                    project: project,
                    fromURL: tmpClipURL,
                    thumb: thumb,
                    duration: actualDuration,
                    isSmartFill: true,
                    previewFillRaw: orientationRaw
                )
            }

            results[day] = tmpClipURL
        }
        return results
    }

    // SHIM: keep old 3-arg signature working (thumbnail discarded)
    @discardableResult
    func fillMissingDays(
        in range: ClosedRange<Date>,
        project: Project,
        duration: TimeInterval = ClipDefaults.duration,
        progress: @escaping (Int, Int, Date) -> Void
    ) async throws -> [Date: URL] {
        return try await fillMissingDays(in: range, project: project, duration: duration) { i, t, d, _ in
            progress(i, t, d)
        }
    }


    // MARK: – “Missing” days helper
    /// A day is “missing” when there is **no** Core-Data row *or*
    /// the row’s file is absent on disk.
    private func missingDays(in month: Date, project: Project) async -> [Date] {
        var out: [Date] = []
        for day in allDays(in: month) {
            // Hop to main only to read from ClipStore
            let clip = await onMain { store.clip(for: day, in: project) }
            guard let clip else { out.append(day); continue }

            let url = await onMain { store.urlForClip(clip) }
            if !fm.fileExists(atPath: url.path) { out.append(day) }
        }
        return out
    }

    private func holesThatHaveLibraryAssets(in month: Date, project: Project) async -> [Date] {
        let holes = await missingDays(in: month, project: project)

        let opts  = PHFetchOptions()
        var out: [Date] = []
        for day in holes {
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                         start as NSDate, end as NSDate)
            if PHAsset.fetchAssets(with: opts).count > 0 {
                out.append(day)
            }
        }
        return out
    }

    // MARK: - Async Photos helpers (fixed)

    private func requestAVURL(for asset: PHAsset) async throws -> URL {
        let opts = PHVideoRequestOptions()
        opts.version = .current
        opts.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, info in
                // Handle cancellation / error from info dictionary
                if let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue, cancelled {
                    cont.resume(throwing: CancellationError()); return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: error); return
                }
                guard let av = av else {
                    cont.resume(throwing: NSError(domain: "SmartFill", code: -10,
                                                  userInfo: [NSLocalizedDescriptionKey:"Missing AVAsset"]))
                    return
                }

                // Fast path: file-backed asset
                if let url = (av as? AVURLAsset)?.url {
                    cont.resume(returning: url)
                    return
                }

                // Fallback: export composition to a temp file
                guard let export = AVAssetExportSession(asset: av, presetName: AVAssetExportPresetPassthrough) else {
                    cont.resume(throwing: NSError(domain: "SmartFill", code: -11,
                                                  userInfo: [NSLocalizedDescriptionKey:"Cannot create export session"]))
                    return
                }
                let outURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                export.outputURL = outURL
                export.outputFileType = .mov
                export.exportAsynchronously {
                    if let err = export.error { cont.resume(throwing: err) }
                    else                       { cont.resume(returning: outURL) }
                }
            }
        }
    }

    private func requestImageData(for asset: PHAsset) async throws -> Data {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, info in
                if let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue, cancelled {
                    cont.resume(throwing: CancellationError()); return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: error); return
                }
                if let data { cont.resume(returning: data) }
                else {
                    cont.resume(throwing: NSError(domain: "SmartFill", code: -12,
                                                  userInfo: [NSLocalizedDescriptionKey:"No image data"]))
                }
            }
        }
    }



    // MARK: – Best PHAsset for a given day (prefers newest video)
    private func bestAsset(for day: Date) -> PHAsset? {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        // Video first
        opts.predicate = NSPredicate(format:
            "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
            start as NSDate, end as NSDate, PHAssetMediaType.video.rawValue)
        if let vid = PHAsset.fetchAssets(with: opts).firstObject { return vid }

        // Then image
        opts.predicate = NSPredicate(format:
            "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
            start as NSDate, end as NSDate, PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(with: opts).firstObject
    }

    // MARK: – Make a clip in /tmp and thumbnail
    /// Returns (clipURL, thumbnail, actualDuration) - actualDuration may be less than requested if video is shorter
    private func makeClip(from asset: PHAsset,
                          duration: TimeInterval,
                          mediaConfig: ClipDefaults.MediaConfig) async throws -> (URL, UIImage, TimeInterval) {
        try Task.checkCancellation()

        if asset.mediaType == .video {
            let inURL = try await requestAVURL(for: asset)

            // Get actual video duration and use the minimum of requested vs actual
            let videoAsset = AVURLAsset(url: inURL)
            let actualVideoDuration = CMTimeGetSeconds(videoAsset.duration)
            let effectiveDuration = min(duration, actualVideoDuration)

            let out = try await VideoEditEngine.exportVideo(
                from: inURL,
                trimTo: effectiveDuration,
                crop: mediaConfig.crop,
                mode: mediaConfig.mode
            )
            let thumb = try ThumbnailGenerator.make(from: out, maxLength: 300)
            return (out, thumb, effectiveDuration)
        } else {
            // For images, we create a video of the requested duration (Ken Burns effect)
            let data = try await requestImageData(for: asset)
            guard let ui = UIImage(data: data) else {
                throw NSError(domain: "SmartFill", code: -13,
                              userInfo: [NSLocalizedDescriptionKey:"Bad image data"])
            }
            let url = try await VideoEditEngine.exportStillKenBurns(
                ui, duration: duration,
                renderSize: mediaConfig.renderSize,
                fps: 30,
                zoomStart: 0.95, zoomEnd: 1.07,
                panStart: CGPoint(x: 0.5, y: 0.45),
                panEnd:   CGPoint(x: 0.5, y: 0.55)
            )
            let thumb = try ThumbnailGenerator.make(from: url, maxLength: 300)
            return (url, thumb, duration)
        }
    }


    // MARK: – Date helpers
    private func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
    }


    private func allDays(in month: Date) -> [Date] {
        let first = startOfMonth(month)
        let range = calendar.range(of: .day, in: .month, for: first)!
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }

}

private extension Calendar {
    func startOfMonth(_ date: Date) -> Date {
        self.date(from: self.dateComponents([.year, .month], from: date))!
    }
}
