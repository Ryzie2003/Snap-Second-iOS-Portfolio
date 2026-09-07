//
//  LibraryPickerViewModel.swift
//  Memoir
//
//  Created by Ryan Zheng on 6/9/25.
//

import Foundation
import UIKit                // UIImage
import Photos
import Combine
import AVFoundation         // CMTime

// MARK: – Grouping Model
struct AssetSection: Identifiable {
    let id = UUID()
    let date: Date
    var assets: [PHAsset]
}

enum IngestMode {
  case editQueue                          // current behavior
  case quickAdd(length: Double, trim: Bool)
}


// MARK: – ViewModel
class LibraryPickerViewModel: ObservableObject {
    // grouped assets by day
    @Published var sections: [AssetSection] = []
    private var allSections: [AssetSection] = []        // full dataset, kept in memory
    private var seedDayKey: Date? = nil                 // normalized day we want to start at
    private var singleDayOnly = false
    // currently-tapped PHAssets
    @Published var selectedAssets: Set<PHAsset> = []
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var isLoadingAssets = false

    // import state
    @Published var isImporting: Bool    = false
    @Published var importProgress: Double = 0  // 0…1
    @Published var importError: String? = nil

    private let project: Project

    init(project: Project) {
        self.project = project
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.authorizationStatus = status
        // ask only once; then fetch
        switch status {
        case .authorized, .limited:
            isLoadingAssets = true
            fetchAndGroupAssets()
        case .notDetermined:
            isLoadingAssets = true
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { new in
                DispatchQueue.main.async {
                    self.authorizationStatus = new
                    if new == .authorized || new == .limited {
                        self.fetchAndGroupAssets()
                    } else {
                        self.isLoadingAssets = false
                    }
                }
            }
        default:
            isLoadingAssets = false
        }
    }

    /// Simple toggle for multi-select
    func toggleSelection(_ asset: PHAsset) {
        if selectedAssets.contains(asset) {
            selectedAssets.remove(asset)
        } else {
            selectedAssets.insert(asset)
        }
    }

    func deselectAll() {
        selectedAssets.removeAll()
    }

    @MainActor
    func seed(startAt date: Date?, singleDayOnly: Bool = false) {   // ← changed
        self.seedDayKey = date.map { Calendar.current.startOfDay(for: $0) }
        self.singleDayOnly = singleDayOnly                           // ← NEW
        if !allSections.isEmpty { rewindow() }
    }

    @MainActor
    private func rewindow() {
        guard !allSections.isEmpty else { sections = []; return }

        if singleDayOnly, let target = seedDayKey {
            if let exact = allSections.first(where: { Calendar.current.isDate($0.date, inSameDayAs: target) }) {
                sections = [exact]
            } else {
                sections = []
            }
            return
        }

        sections = allSections
    }






    /// Load & group assets from the photo library
    private func fetchAndGroupAssets() {
        DispatchQueue.main.async {
            self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            self.isLoadingAssets = true
        }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        if let seed = seedDayKey, singleDayOnly {
            let start = seed as NSDate
            let end = Calendar.current.date(byAdding: .day, value: 1, to: seed)! as NSDate
            let dayPredicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start, end)
            opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [opts.predicate!, dayPredicate])
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let all = PHAsset.fetchAssets(with: opts)
            var byDay: [Date: [PHAsset]] = [:]
            all.enumerateObjects { asset, _, _ in
                guard let d = asset.creationDate else { return }
                let k = Calendar.current.startOfDay(for: d)
                byDay[k, default: []].append(asset)
            }

            let mapped = byDay
                .map { AssetSection(date: $0.key, assets: $0.value) }
                .sorted { $0.date > $1.date }

            DispatchQueue.main.async {
                self.allSections = mapped
                self.rewindow()                 // ← choose the initial window based on seed
                self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                self.isLoadingAssets = false
            }
        }
    }
}

// MARK: – Bulk-Import Logic
extension LibraryPickerViewModel {
    /// Trims each selected asset to 1s (or converts image → 1s video),
    /// generates a thumbnail, and saves via your ClipStore API.
    // MARK: – Bulk-Import / Edit-Queue entry point
    func importSelectedAssets(
        mode: IngestMode,
        completion: @escaping (Result<Int, Error>) -> Void = { _ in }
    ) {
        guard !selectedAssets.isEmpty else {
            completion(.success(0)); return
        }

        switch mode {
        case .editQueue:
            // Keep current behavior: notify presenter to open editor(s)
            let ids = Array(selectedAssets).map { $0.localIdentifier }
            var seen = Set<String>()
            let unique = ids.filter { seen.insert($0).inserted }

            if unique.count == 1, let id = unique.first {
                NotificationCenter.default.post(
                    name: .libraryPickerPicked,
                    object: nil,
                    userInfo: ["localIdentifier": id]
                )
            } else {
                NotificationCenter.default.post(
                    name: .libraryPickerPickedMany,
                    object: nil,
                    userInfo: ["localIdentifiers": unique]
                )
            }
            completion(.success(0))
            return

        case .quickAdd(let length, let trim):
            break // fall through to headless ingest below
        }

        // -------- Quick Add (headless) ----------
        isImporting    = true
        importError    = nil
        importProgress = 0

        // stable order + de-dupe by localIdentifier
        var seen = Set<String>()
        let assets = Array(selectedAssets)
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            .filter { seen.insert($0.localIdentifier).inserted }

        let total = assets.count

        Task.detached { [weak self] in
            guard let self else { return }
            var saved = 0

            let orientationRaw = ClipDefaults.orientationRaw
            let mediaConfig = ClipDefaults.mediaConfig(for: orientationRaw)

            do {
                for (idx, asset) in assets.enumerated() {
                    let day = (asset.creationDate.map { Calendar.current.startOfDay(for: $0) }) ?? Calendar.current.startOfDay(for: Date())

                    // Helper: export Live Photo paired video if present
                    func livePhotoVideoURL(_ a: PHAsset) async throws -> URL {
                        let res = PHAssetResource.assetResources(for: a)
                        guard let vid = res.first(where: { $0.type == .pairedVideo }) else {
                            throw NSError(domain: "QuickAdd", code: -20,
                                          userInfo: [NSLocalizedDescriptionKey: "No paired video in Live Photo"])
                        }
                        let dst = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                            PHAssetResourceManager.default().writeData(for: vid, toFile: dst, options: nil) { err in
                                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
                            }
                        }
                        return dst
                    }

                    do {
                        switch asset.mediaType {
                        case .image:
                            if asset.mediaSubtypes.contains(.photoLive) {
                                // Prefer the motion part of Live Photo
                                let src = try await livePhotoVideoURL(asset)
                                // After you get `src` (paired .mov):
                                let url: URL
                                let dur: Double
                                if case .quickAdd(let length, let trim) = mode, trim {
                                    url = try await VideoEditEngine.exportVideo(
                                        from: src,
                                        trimTo: length,
                                        crop: mediaConfig.crop,
                                        mode: mediaConfig.mode
                                    )
                                    dur = length
                                } else {
                                    url = try await VideoEditEngine.exportVideo(
                                        from: src,
                                        trimTo: nil,
                                        crop: mediaConfig.crop,
                                        mode: mediaConfig.mode
                                    )
                                    dur = CMTimeGetSeconds(AVURLAsset(url: url).duration)
                                }

                                let thumb = try ThumbnailGenerator.make(from: url, maxLength: 300)
                                await ClipStore.shared.addClip(
                                    for: day,
                                    project: self.project,
                                    fromURL: url,
                                    thumb: thumb,
                                    duration: dur,            // Double, not Int
                                    isSmartFill: false,
                                    start: 0.0,               // Double
                                    sourceLocalID: asset.localIdentifier,
                                    previewFillRaw: orientationRaw,
                                    mediaType: .livePhoto
                                )
                            } else {
                                // Still → short video of chosen length
                                let data = try await asset.requestImageData()
                                guard let img = UIImage(data: data)?.fixedOrientation() else {
                                    throw NSError(domain: "QuickAdd", code: -10,
                                                  userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
                                }
                                let duration: Double
                                if case .quickAdd(let l, _) = mode { duration = l } else { duration = ClipDefaults.duration }
                                let url = try await VideoEditEngine.exportStillKenBurns(
                                    img,
                                    duration: duration,
                                    renderSize: mediaConfig.renderSize,
                                    fps: 30,
                                    zoomStart: 1.03,
                                    zoomEnd:   1.10,
                                    panStart: CGPoint(x: 0.5, y: 0.45),
                                    panEnd:   CGPoint(x: 0.5, y: 0.55)
                                )
                                let thumb = try ThumbnailGenerator.make(from: url, maxLength: 300)
                                await ClipStore.shared.addClip(
                                    for: day,
                                    project: self.project,
                                    fromURL: url,
                                    thumb: thumb,
                                    duration: duration,    // Double
                                    isSmartFill: false,
                                    start: 0.0,            // Double
                                    sourceLocalID: asset.localIdentifier,
                                    previewFillRaw: orientationRaw,
                                    mediaType: .photo
                                )

                            }

                        case .video:
                            let src = try await asset.fileURL()
                            let url: URL
                            let dur: Double
                            if case .quickAdd(let length, let trim) = mode, trim {
                                url = try await VideoEditEngine.exportVideo(
                                    from: src,
                                    trimTo: length,
                                    crop: mediaConfig.crop,
                                    mode: mediaConfig.mode
                                )
                                dur = length
                            } else {
                                url = try await VideoEditEngine.exportVideo(
                                    from: src,
                                    trimTo: nil,
                                    crop: mediaConfig.crop,
                                    mode: mediaConfig.mode
                                )
                                dur = CMTimeGetSeconds(AVURLAsset(url: url).duration)
                            }
                            let thumb = try ThumbnailGenerator.make(from: url, maxLength: 300)
                            await ClipStore.shared.addClip(
                                for: day,
                                project: self.project,
                                fromURL: url,
                                thumb: thumb,
                                duration: dur,       // Double
                                isSmartFill: false,
                                start: 0.0,          // Double
                                sourceLocalID: asset.localIdentifier,
                                previewFillRaw: orientationRaw,
                                mediaType: .video
                            )

                        default:
                            break
                        }

                        saved += 1
                    } catch {
                        await MainActor.run {
                            if self.importError == nil { self.importError = error.localizedDescription }
                        }
                    }

                    await MainActor.run {
                        self.importProgress = total > 0 ? Double(idx + 1) / Double(total) : 1
                    }
                }

                await MainActor.run {
                    self.isImporting = false
                    self.selectedAssets.removeAll()
                    completion(.success(saved))
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.importError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }
}

private enum SortOrder { case ascending, descending }

private extension Array where Element == AssetSection {
    /// Finds index of target day or nearest newer day in a day-sorted array.
    func binarySearch(where key: (AssetSection) -> Date,
                      for target: Date,
                      order: SortOrder) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            let d = key(self[mid])
            switch order {
            case .descending:
                if d >= target { hi = mid } else { lo = mid + 1 }
            case .ascending:
                if d < target { lo = mid + 1 } else { hi = mid }
            }
        }
        return lo
    }
}
